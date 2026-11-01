//
//  OpencodeBackend.swift
//  Command Space
//
//  System Two on a local `opencode serve` instance, over HTTP + SSE.
//

import Defaults
import Foundation

@MainActor
final class OpencodeBackend: AgentBackend {
    let harness = SystemTwoHarness.opencode
    private(set) var connection: AgentConnection = .connecting { didSet { notify(oldValue != connection) } }
    private(set) var modelState: AgentModelState = .unknown { didSet { notify(oldValue != modelState) } }

    private var eventTask: Task<Void, Never>?
    /// messageID -> role, per session (parts don't carry their role).
    private var roles: [String: String] = [:]

    private var baseURL: URL { URL(string: Defaults[.agentServerURL]) ?? URL(string: "http://127.0.0.1:4096")! }

    private func notify(_ changed: Bool) { if changed { AgentBackendSink.changed(harness) } }

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in await self?.runEventLoop() }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        connection = .connecting
    }

    // MARK: Sessions

    func createSession() async throws -> String {
        let data = try await request("POST", "/session", body: [String: Any]())
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    func send(_ text: String, context: String?, mode: AgentMode, to session: String) async throws {
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        // Sent as a hidden (synthetic) part so the chat shows only what was said.
        if let context { parts.insert(["type": "text", "text": context, "synthetic": true], at: 0) }
        var body: [String: Any] = ["parts": parts]
        // Plan mode is opencode's built-in plan agent. Other modes use the workspace's own agent;
        // Command Space answers the approvals those modes skip.
        if mode == .plan { body["agent"] = "plan" }
        let override = Defaults[.agentModelOverride]
        if let slash = override.firstIndex(of: "/") {
            body["model"] = ["providerID": String(override[..<slash]),
                             "modelID": String(override[override.index(after: slash)...])]
        }
        _ = try await request("POST", "/session/\(session)/prompt_async", body: body)
    }

    func setMode(_ mode: AgentMode, for session: String) {}

    func abort(_ session: String) {
        Task { _ = try? await request("POST", "/session/\(session)/abort") }
    }

    func reply(to permission: AgentPermission, with reply: PermissionReply) {
        Task { _ = try? await request("POST", "/permission/\(permission.id)/reply", body: ["reply": reply.rawValue]) }
    }

    func listSessions() async -> [AgentSessionSummary] {
        guard let data = try? await request("GET", "/session"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { info -> AgentSessionSummary? in
            guard let id = info["id"] as? String, info["parentID"] == nil else { return nil }
            let time = info["time"] as? [String: Any]
            let created = (time?["created"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let updated = (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? created
            return AgentSessionSummary(id: id, harness: .opencode, title: info["title"] as? String ?? "",
                                       created: created, updated: updated)
        }
    }

    func snapshot(of session: String) async -> AgentSnapshot? {
        guard let data = try? await request("GET", "/session/\(session)/message"),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var items: [AgentItem] = []
        for message in messages {
            guard let info = message["info"] as? [String: Any], let mid = info["id"] as? String else { continue }
            roles[mid] = info["role"] as? String
            for part in message["parts"] as? [[String: Any]] ?? [] {
                if let item = makeItem(from: part, includeUser: true) { items.append(item) }
            }
        }
        var permissions: [AgentPermission] = []
        if let data = try? await request("GET", "/permission"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            permissions = list.compactMap(Self.makePermission).filter { $0.sessionID == session }
        }
        var busy = false
        if let data = try? await request("GET", "/session/status"),
           let statuses = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            busy = ((statuses[session] as? [String: Any])?["type"] as? String) == "busy"
        }
        return AgentSnapshot(items: items, permissions: permissions, busy: busy, title: nil)
    }

    func delete(_ session: String) async {
        _ = try? await request("DELETE", "/session/\(session)")
    }

    // MARK: Model

    /// Asks llama-server (through the proxy) whether the model is loaded.
    func refreshModelState() {
        let override = Defaults[.agentModelOverride]
        if let slash = override.firstIndex(of: "/"), override[..<slash] != "local" {
            modelState = .cloud(provider: String(override[..<slash]), model: String(override[override.index(after: slash)...]))
            return
        }
        Task {
            guard let url = URL(string: Defaults[.agentModelURL] + "/props") else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                modelState = .unreachable
                return
            }
            let name = (props["model_alias"] as? String) ?? "Local model"
            modelState = (props["is_sleeping"] as? Bool) == true ? .asleep(name) : .ready(name)
        }
    }

    // MARK: Events

    private func runEventLoop() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            connection = .connecting
            do {
                var req = URLRequest(url: baseURL.appendingPathComponent("event"))
                req.timeoutInterval = .infinity
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                connection = .connected
                delay = 1
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    dispatch(event)
                }
                throw URLError(.networkConnectionLost)
            } catch {
                if Task.isCancelled { return }
                connection = .offline("opencode isn’t running on \(baseURL.host ?? ""):\(baseURL.port ?? 0)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 15)
            }
        }
    }

    private func dispatch(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let props = event["properties"] as? [String: Any] else { return }
        let sessionID = (props["sessionID"] as? String)
            ?? ((props["part"] as? [String: Any])?["sessionID"] as? String)
            ?? ((props["info"] as? [String: Any])?["sessionID"] as? String)
            ?? (type.hasPrefix("session.") ? (props["info"] as? [String: Any])?["id"] as? String : nil)
        guard let sessionID else { return }
        for event in translate(type: type, props: props) {
            AgentBackendSink.event(harness, sessionID, event)
        }
    }

    private func translate(type: String, props: [String: Any]) -> [AgentEvent] {
        switch type {
        case "message.updated":
            guard let info = props["info"] as? [String: Any], let id = info["id"] as? String else { return [] }
            roles[id] = info["role"] as? String
            if let error = info["error"] as? [String: Any], (error["name"] as? String) != "MessageAbortedError" {
                let data = error["data"] as? [String: Any]
                return [.error(data?["message"] as? String ?? error["name"] as? String ?? "Unknown error")]
            }
            return []
        case "message.part.updated":
            guard let part = props["part"] as? [String: Any] else { return [] }
            var events: [AgentEvent] = []
            if part["type"] as? String == "step-start" { events.append(.step) }
            if let item = makeItem(from: part, includeUser: false) { events.append(.item(item)) }
            return events
        case "message.part.delta":
            guard (props["field"] as? String) == "text",
                  let partID = props["partID"] as? String,
                  let delta = props["delta"] as? String,
                  roles[props["messageID"] as? String ?? ""] != "user" else { return [] }
            return [.delta(id: partID, text: delta)]
        case "session.status":
            let info = props["status"] as? [String: Any]
            let status = info?["type"] as? String
            var events: [AgentEvent] = [.busy(status == "busy" || status == "retry")]
            if status == "retry" {
                let next = (info?["next"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                events.append(.retry(AgentRetry(attempt: info?["attempt"] as? Int ?? 1,
                                                message: info?["message"] as? String ?? "Retrying", next: next)))
            } else {
                events.append(.retry(nil))
            }
            return events
        case "session.idle":
            return [.busy(false)]
        case "session.updated":
            if let info = props["info"] as? [String: Any], let title = info["title"] as? String { return [.title(title)] }
            return []
        case "session.error":
            guard let error = props["error"] as? [String: Any], (error["name"] as? String) != "MessageAbortedError" else { return [] }
            let data = error["data"] as? [String: Any]
            if (error["name"] as? String)?.contains("ModelNotFound") == true {
                return [.error("The model “\(Defaults[.agentModelOverride])” isn't available. Choose another in Settings → System Two."), .busy(false)]
            }
            return [.error(data?["message"] as? String ?? error["name"] as? String ?? "Agent error"), .busy(false)]
        case "permission.asked":
            return Self.makePermission(props).map { [.permission($0)] } ?? []
        case "permission.replied":
            return (props["requestID"] as? String).map { [.permissionResolved($0)] } ?? []
        default:
            return []
        }
    }

    private func makeItem(from part: [String: Any], includeUser: Bool) -> AgentItem? {
        guard let id = part["id"] as? String, let type = part["type"] as? String else { return nil }
        let role = roles[part["messageID"] as? String ?? ""]
        switch type {
        case "text":
            if part["synthetic"] as? Bool == true { return nil }
            if role == "user" && !includeUser { return nil }
            let text = part["text"] as? String ?? ""
            return AgentItem(id: id, kind: role == "user" ? .user : .assistant, text: text)
        case "tool":
            let tool = part["tool"] as? String ?? "tool"
            let state = part["state"] as? [String: Any] ?? [:]
            let status = state["status"] as? String ?? "pending"
            let input = state["input"] as? [String: Any] ?? [:]
            var summary = (input["command"] as? String)
                ?? (input["filePath"] as? String)
                ?? (input["url"] as? String)
                ?? (input["pattern"] as? String)
                ?? (state["title"] as? String)
                ?? ""
            if status == "error", let error = state["error"] as? String {
                summary += summary.isEmpty ? error : "\n" + (error.components(separatedBy: "\n").first ?? error)
            }
            return AgentItem(id: id, kind: .tool(name: tool, status: status), text: summary,
                             callID: part["callID"] as? String)
        default:
            return nil
        }
    }

    static func makePermission(_ props: [String: Any]) -> AgentPermission? {
        guard let id = props["id"] as? String, let session = props["sessionID"] as? String else { return nil }
        return AgentPermission(
            id: id,
            sessionID: session,
            permission: props["permission"] as? String ?? "action",
            patterns: props["patterns"] as? [String] ?? [],
            callID: (props["tool"] as? [String: Any])?["callID"] as? String
        )
    }

    // MARK: HTTP

    @discardableResult
    func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = 15
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
