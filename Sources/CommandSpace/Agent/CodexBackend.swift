//
//  CodexBackend.swift
//  Command Space
//
//  System Two on the user's own Codex CLI: one `codex app-server` (JSON-RPC over stdio) serves
//  every Codex conversation. Codex uses the ChatGPT account it's logged into (`codex login`), so
//  requests count against the user's ChatGPT plan; Command Space refuses to run it on an API key.
//
//  Approvals: `untrusted` runs read-only commands Codex knows are safe and asks for everything
//  else, the same as Space's opencode setup (which asks for every command and edit).
//

import Defaults
import Foundation

@MainActor
final class CodexBackend: AgentBackend {
    let harness = SystemTwoHarness.codex
    private(set) var connection: AgentConnection = .connecting { didSet { notify(oldValue != connection) } }
    private(set) var modelState: AgentModelState = .unknown { didSet { notify(oldValue != modelState) } }
    /// Models the signed-in account can use, for Settings.
    private(set) var models: [(id: String, name: String)] = [] { didSet { AgentBackendSink.changed(harness) } }
    private(set) var plan: String?

    private var process: JSONLineProcess?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var launching = false
    private var restartDelay: Double = 1
    /// Threads loaded in this app-server (others need `thread/resume` first).
    private var loaded: Set<String> = []
    private var activeTurn: [String: String] = [:]
    /// Approval id -> the JSON-RPC request id to answer, and what kind of approval it is.
    private var approvals: [String: (rpcID: Any, method: String)] = [:]
    private var commandNames: [String: String] = [:]

    private func notify(_ changed: Bool) { if changed { AgentBackendSink.changed(harness) } }

    struct CodexError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Lifecycle

    func start() {
        guard process == nil, !launching else { return }
        launching = true
        connection = .connecting
        Task {
            defer { launching = false }
            guard let binary = await Task.detached(operation: { HarnessDetector.locate("codex") }).value else {
                connection = .offline("Codex isn’t installed. \(SystemTwoHarness.codex.installHint)")
                return
            }
            let process = JSONLineProcess(
                executable: binary, arguments: ["app-server"],
                environment: HarnessEnvironment.codex(binary: binary), directory: SpaceWorkspace.url,
                onMessage: { [weak self] in self?.receive($0) },
                onExit: { [weak self] status, stderr in self?.exited(status: status, stderr: stderr) }
            )
            do {
                try process.launch()
            } catch {
                connection = .offline("Couldn’t start Codex: \(error.localizedDescription)")
                return
            }
            self.process = process
            do {
                _ = try await call("initialize", ["clientInfo": ["name": "command-space", "title": "Command Space",
                                                                 "version": Self.appVersion]])
                process.send(["method": "initialized"])
                try await checkAccount()
                restartDelay = 1
                refreshModelState()
                Task { await loadModels() }
            } catch {
                if case .connecting = connection {
                    connection = .offline("Codex didn’t start: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        let process = self.process
        self.process = nil
        process?.terminate()
        failPending()
        loaded = []
        activeTurn = [:]
        connection = .connecting
    }

    private func exited(status: Int32, stderr: String) {
        guard process != nil else { return }  // stopped on purpose
        process = nil
        failPending()
        loaded = []
        approvals = [:]
        for permission in openPermissions.values {
            AgentBackendSink.event(harness, permission.sessionID, .permissionResolved(permission.id))
        }
        openPermissions = [:]
        for session in activeTurn.keys { AgentBackendSink.event(harness, session, .busy(false)) }
        activeTurn = [:]
        let tail = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
        connection = .offline("Codex stopped (\(tail)). Restarting…")
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if AgentManager.shared.wants(.codex) { start() }
        }
    }

    private func checkAccount() async throws {
        let result = try await call("account/read", ["refreshToken": false]) as? [String: Any]
        let account = result?["account"] as? [String: Any]
        switch account?["type"] as? String {
        case "chatgpt":
            plan = (account?["planType"] as? String).map { "ChatGPT " + $0.capitalized }
            connection = .connected
        case "apiKey":
            connection = .offline("Codex is signed in with an API key. Run `codex logout`, then `codex login` and choose Sign in with ChatGPT.")
        default:
            connection = .offline("Codex isn’t signed in. Run `codex login` in Terminal.")
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Requests

    private var threadSettings: [String: Any] {
        var settings: [String: Any] = [
            "cwd": SpaceWorkspace.url.path,
            "approvalPolicy": "untrusted",
            "sandbox": "danger-full-access",
            "developerInstructions": SpaceWorkspace.instructions,
        ]
        let model = Defaults[.codexModel]
        if !model.isEmpty { settings["model"] = model }
        return settings
    }

    func createSession() async throws -> String {
        try await ready()
        var params = threadSettings
        params["serviceName"] = "Command Space"
        let result = try await call("thread/start", params) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any], let id = thread["id"] as? String else {
            throw CodexError(message: "Codex didn’t start a conversation")
        }
        loaded.insert(id)
        return id
    }

    func send(_ text: String, context: String?, to session: String) async throws {
        try await ready()
        if !loaded.contains(session) {
            var params = threadSettings
            params["threadId"] = session
            params["excludeTurns"] = true
            _ = try await call("thread/resume", params)
            loaded.insert(session)
        }
        let message = context.map { SpaceWorkspace.wrap(context: $0, around: text) } ?? text
        var params: [String: Any] = ["threadId": session, "input": [["type": "text", "text": message]]]
        let model = Defaults[.codexModel]
        if !model.isEmpty { params["model"] = model }
        AgentBackendSink.event(harness, session, .busy(true))
        do {
            let result = try await call("turn/start", params) as? [String: Any]
            if let turn = (result?["turn"] as? [String: Any])?["id"] as? String { activeTurn[session] = turn }
        } catch {
            AgentBackendSink.event(harness, session, .busy(false))
            throw error
        }
    }

    func abort(_ session: String) {
        guard let turn = activeTurn[session] else { return }
        Task { _ = try? await call("turn/interrupt", ["threadId": session, "turnId": turn]) }
    }

    func reply(to permission: AgentPermission, with reply: PermissionReply) {
        guard let approval = approvals.removeValue(forKey: permission.id) else { return }
        let decision: String
        switch reply {
        case .once: decision = "accept"
        case .always: decision = "acceptForSession"
        case .reject: decision = "decline"
        }
        if approval.method == "item/permissions/requestApproval" {
            // Grant what was asked for this turn, or nothing.
            let granted = reply == .reject ? [String: Any]() : (permissionRequests[permission.id] ?? [:])
            respond(approval.rpcID, ["permissions": granted, "scope": reply == .always ? "session" : "turn"])
        } else {
            respond(approval.rpcID, ["decision": decision])
        }
        permissionRequests[permission.id] = nil
        openPermissions[permission.id] = nil
        AgentBackendSink.event(harness, permission.sessionID, .permissionResolved(permission.id))
    }

    private var permissionRequests: [String: [String: Any]] = [:]

    func listSessions() async -> [AgentSessionSummary] {
        guard (try? await ready()) != nil,
              let result = try? await call("thread/list", ["limit": 200, "sortKey": "updated_at"]) as? [String: Any],
              let data = result["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { thread in
            // Only conversations started from Command Space, not coding sessions in other folders.
            guard let id = thread["id"] as? String, thread["originator"] as? String == "command-space",
                  thread["parentThreadId"] as? String == nil else { return nil }
            let created = Date(timeIntervalSince1970: thread["createdAt"] as? Double ?? 0)
            let updated = Date(timeIntervalSince1970: thread["updatedAt"] as? Double ?? 0)
            let preview = SpaceWorkspace.stripContext(thread["preview"] as? String ?? "")
            let title = (thread["name"] as? String) ?? String(preview.prefix(80))
            return AgentSessionSummary(id: id, harness: .codex, title: title, created: created, updated: updated)
        }
    }

    func snapshot(of session: String) async -> AgentSnapshot? {
        guard (try? await ready()) != nil,
              let result = try? await call("thread/read", ["threadId": session, "includeTurns": true]) as? [String: Any],
              let thread = result["thread"] as? [String: Any] else { return nil }
        var items: [AgentItem] = []
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            for raw in turn["items"] as? [[String: Any]] ?? [] {
                if let item = makeItem(raw, includeUser: true) { items.append(item) }
            }
            if turn["status"] as? String == "failed",
               let message = (turn["error"] as? [String: Any])?["message"] as? String {
                items.append(AgentItem(id: UUID().uuidString, kind: .error, text: message))
            }
        }
        let busy = ((thread["status"] as? [String: Any])?["type"] as? String) == "active"
        let pendingHere = openPermissions.values.filter { $0.sessionID == session }
        return AgentSnapshot(items: items, permissions: pendingHere, busy: busy, title: thread["name"] as? String)
    }

    func delete(_ session: String) async {
        _ = try? await call("thread/delete", ["threadId": session])
        loaded.remove(session)
    }

    func refreshModelState() {
        let model = Defaults[.codexModel]
        let name = model.isEmpty ? (defaultModel ?? "Codex default model") : (models.first { $0.id == model }?.name ?? model)
        modelState = .cloud(provider: "chatgpt", model: name)
    }

    private func loadModels() async {
        guard let result = try? await call("model/list", ["limit": 50]) as? [String: Any],
              let data = result["data"] as? [[String: Any]] else { return }
        models = data.compactMap { model in
            guard let id = (model["model"] as? String) ?? (model["id"] as? String) else { return nil }
            if model["hidden"] as? Bool == true { return nil }
            let name = (model["displayName"] as? String) ?? id
            if model["isDefault"] as? Bool == true { defaultModel = name }
            return (id, name)
        }
        refreshModelState()
    }

    private var defaultModel: String?

    /// Waits for the app-server to be up and signed in.
    private func ready() async throws {
        start()
        for _ in 0..<150 {
            if case .connected = connection, process != nil { return }
            if case .offline(let reason) = connection, !launching { throw CodexError(message: reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CodexError(message: "Codex is taking too long to start")
    }

    // MARK: JSON-RPC

    private func call(_ method: String, _ params: [String: Any]) async throws -> Any? {
        guard let process else { throw CodexError(message: "Codex isn’t running") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            process.send(["id": id, "method": method, "params": params])
        }
    }

    private func respond(_ id: Any, _ result: [String: Any]) {
        process?.send(["id": id, "result": result])
    }

    private func failPending() {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: CodexError(message: "Codex stopped")) }
    }

    private func receive(_ message: [String: Any]) {
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            handleServerRequest(method, id: id, params: message["params"] as? [String: Any] ?? [:])
        } else if let method {
            handleNotification(method, message["params"] as? [String: Any] ?? [:])
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: CodexError(message: error["message"] as? String ?? "Codex error"))
            } else {
                continuation.resume(returning: message["result"])
            }
        }
    }

    // MARK: Server → app

    private func handleServerRequest(_ method: String, id: Any, params: [String: Any]) {
        guard let session = params["threadId"] as? String else {
            process?.send(["id": id, "error": ["code": -32601, "message": "Not supported by Command Space"]])
            return
        }
        let approvalID = "codex-\(id)"
        let callID = params["itemId"] as? String
        switch method {
        case "item/commandExecution/requestApproval":
            approvals[approvalID] = (id, method)
            var command = Self.shortCommand(params["command"] as? String ?? "")
            if command.isEmpty, let item = callID { command = commandNames[item] ?? "" }
            if let reason = params["reason"] as? String, !reason.isEmpty { command += command.isEmpty ? reason : "\n" + reason }
            emitPermission(approvalID, session: session, kind: "bash", pattern: command, callID: callID)
        case "item/fileChange/requestApproval":
            approvals[approvalID] = (id, method)
            emitPermission(approvalID, session: session, kind: "edit",
                           pattern: (params["reason"] as? String) ?? commandNames[callID ?? ""] ?? "Change files", callID: callID)
        case "item/permissions/requestApproval":
            approvals[approvalID] = (id, method)
            permissionRequests[approvalID] = params["permissions"] as? [String: Any] ?? [:]
            emitPermission(approvalID, session: session, kind: "permissions",
                           pattern: (params["reason"] as? String) ?? "Extra access", callID: callID)
        case "mcpServer/elicitation/request":
            process?.send(["id": id, "result": ["action": "decline"]])
        case "item/tool/requestUserInput":
            process?.send(["id": id, "result": ["answers": [String: Any]()]])
        default:
            process?.send(["id": id, "error": ["code": -32601, "message": "Not supported by Command Space"]])
        }
    }

    private func emitPermission(_ id: String, session: String, kind: String, pattern: String, callID: String?) {
        let permission = AgentPermission(id: id, sessionID: session, permission: kind, patterns: [pattern], callID: callID)
        openPermissions[id] = permission
        AgentBackendSink.event(harness, session, .permission(permission))
    }

    private var openPermissions: [String: AgentPermission] = [:]

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        if method == "account/updated" {
            Task { try? await checkAccount() }
            return
        }
        guard let session = params["threadId"] as? String else { return }
        let send = { (event: AgentEvent) in AgentBackendSink.event(self.harness, session, event) }
        switch method {
        case "turn/started":
            if let turn = (params["turn"] as? [String: Any])?["id"] as? String { activeTurn[session] = turn }
            send(.busy(true))
        case "turn/completed":
            activeTurn[session] = nil
            let turn = params["turn"] as? [String: Any]
            if turn?["status"] as? String == "failed",
               let message = (turn?["error"] as? [String: Any])?["message"] as? String {
                send(.error(message))
            }
            send(.retry(nil))
            send(.busy(false))
        case "item/started", "item/completed":
            guard let raw = params["item"] as? [String: Any] else { return }
            if raw["type"] as? String == "agentMessage" || raw["type"] as? String == "commandExecution" {
                if method == "item/started" { send(.step) }
            }
            if let item = makeItem(raw, includeUser: false) {
                // Streaming already filled the text in; an empty "started" copy would erase it.
                if method == "item/started", item.kind == .assistant, item.text.isEmpty { return }
                send(.item(item))
            }
        case "item/agentMessage/delta":
            if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                send(.delta(id: id, text: delta))
            }
        case "thread/name/updated":
            if let name = params["threadName"] as? String { send(.title(name)) }
        case "thread/tokenUsage/updated":
            if let last = (params["tokenUsage"] as? [String: Any])?["last"] as? [String: Any],
               let tokens = last["outputTokens"] as? Int, tokens > 0 {
                send(.generated(tokens: tokens, seconds: nil))
            }
        case "error":
            let message = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex error"
            if params["willRetry"] as? Bool == true {
                send(.retry(AgentRetry(attempt: 1, message: message, next: nil)))
            } else {
                send(.error(message))
            }
        case "serverRequest/resolved":
            // Answered elsewhere (or timed out): drop the approval card.
            if let id = params["requestId"] {
                let approvalID = "codex-\(id)"
                if approvals.removeValue(forKey: approvalID) != nil {
                    openPermissions[approvalID] = nil
                    send(.permissionResolved(approvalID))
                }
            }
        default:
            break
        }
    }

    // MARK: Items

    private func makeItem(_ raw: [String: Any], includeUser: Bool) -> AgentItem? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String else { return nil }
        switch type {
        case "userMessage":
            guard includeUser else { return nil }
            let text = (raw["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let said = SpaceWorkspace.stripContext(text)
            return said.isEmpty ? nil : AgentItem(id: id, kind: .user, text: said)
        case "agentMessage":
            return AgentItem(id: id, kind: .assistant, text: raw["text"] as? String ?? "")
        case "commandExecution":
            let command = Self.shortCommand(raw["command"] as? String ?? "")
            commandNames[id] = command
            var text = command
            let status = Self.status(raw["status"] as? String)
            if status == "error", let output = raw["aggregatedOutput"] as? String,
               let last = output.split(separator: "\n").last {
                text += "\n" + last
            }
            return AgentItem(id: id, kind: .tool(name: "bash", status: status), text: text, callID: id)
        case "fileChange":
            let paths = (raw["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            let text = paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
            commandNames[id] = text
            return AgentItem(id: id, kind: .tool(name: "edit", status: Self.status(raw["status"] as? String)),
                             text: text, callID: id)
        case "mcpToolCall":
            let name = "\(raw["server"] as? String ?? "mcp").\(raw["tool"] as? String ?? "tool")"
            var status = Self.status(raw["status"] as? String)
            if raw["error"] as? [String: Any] != nil { status = "error" }
            return AgentItem(id: id, kind: .tool(name: name, status: status), text: "", callID: id)
        case "webSearch":
            return AgentItem(id: id, kind: .tool(name: "websearch", status: "completed"),
                             text: raw["query"] as? String ?? "", callID: id)
        default:
            return nil
        }
    }

    private static func status(_ codex: String?) -> String {
        switch codex {
        case "inProgress": return "running"
        case "completed": return "completed"
        case "failed", "declined": return "error"
        default: return "pending"
        }
    }

    /// "/bin/zsh -lc 'date'" → "date"
    nonisolated static func shortCommand(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc ", "/bin/sh -c "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if rest.count >= 2, let first = rest.first, first == rest.last, first == "'" || first == "\"" {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return command
    }
}
