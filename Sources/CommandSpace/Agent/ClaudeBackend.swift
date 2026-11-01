//
//  ClaudeBackend.swift
//  Command Space
//
//  System Two on the user's own Claude Code CLI, signed in with their Claude subscription.
//  Each conversation runs its own `claude -p` process in stream-json mode, which stays up for
//  follow-ups and quits after a few idle minutes (the next message resumes it with --resume).
//  Approvals come back over stdio (--permission-prompt-tool stdio) and show as Command Space's
//  approval cards. History is read from Claude Code's own session files for the workspace.
//

import Defaults
import Foundation

@MainActor
final class ClaudeBackend: AgentBackend {
    let harness = SystemTwoHarness.claudeCode
    private(set) var connection: AgentConnection = .connecting { didSet { notify(oldValue != connection) } }
    private(set) var modelState: AgentModelState = .unknown { didSet { notify(oldValue != modelState) } }

    private var binary: String?
    private var checking = false
    private var live: [String: ClaudeSession] = [:]
    /// The model Claude Code last reported using.
    private var reportedModel: String?

    private func notify(_ changed: Bool) { if changed { AgentBackendSink.changed(harness) } }

    struct ClaudeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Lifecycle

    func start() {
        guard binary == nil || connection != .connected, !checking else { return }
        checking = true
        connection = .connecting
        Task {
            defer { checking = false }
            await HarnessDetector.shared.refresh()
            let status = HarnessDetector.shared.status(.claudeCode)
            guard let path = status.path else {
                connection = .offline("Claude Code isn’t installed. \(SystemTwoHarness.claudeCode.installHint)")
                return
            }
            binary = path
            if status.usesAPIKey {
                connection = .offline("Claude Code is signed in with an API key. Run `claude` and use /login to sign in with your Claude subscription.")
            } else if status.loggedIn == false {
                connection = .offline("Claude Code isn’t signed in. Run `claude` in Terminal and log in.")
            } else {
                connection = .connected
                refreshModelState()
            }
        }
    }

    func stop() {
        for session in live.values { session.terminate() }
        live = [:]
        binary = nil
        connection = .connecting
    }

    func refreshModelState() {
        let chosen = Defaults[.claudeModel]
        let name = chosen.isEmpty ? (reportedModel.map(Self.prettyModel) ?? "Claude Code default model") : Self.prettyModel(chosen)
        modelState = .cloud(provider: "claude", model: name)
    }

    nonisolated static func prettyModel(_ id: String) -> String {
        // "claude-opus-5-5" → "Opus 5.5", "sonnet" → "Sonnet"
        var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        parts.removeFirst()
        let version = parts.prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    // MARK: Requests

    func createSession() async throws -> String {
        try await ready()
        return UUID().uuidString.lowercased()
    }

    func send(_ text: String, context: String?, to session: String) async throws {
        try await ready()
        let conversation = try process(for: session)
        let message = context.map { SpaceWorkspace.wrap(context: $0, around: text) } ?? text
        AgentBackendSink.event(harness, session, .busy(true))
        conversation.send(message)
    }

    func abort(_ session: String) {
        live[session]?.interrupt()
    }

    func reply(to permission: AgentPermission, with reply: PermissionReply) {
        live[permission.sessionID]?.reply(to: permission.id, with: reply)
        AgentBackendSink.event(harness, permission.sessionID, .permissionResolved(permission.id))
    }

    private func ready() async throws {
        start()
        for _ in 0..<100 {
            if case .connected = connection, binary != nil { return }
            if case .offline(let reason) = connection, !checking { throw ClaudeError(message: reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClaudeError(message: "Claude Code is taking too long to start")
    }

    private func process(for session: String) throws -> ClaudeSession {
        if let existing = live[session], existing.isRunning { return existing }
        guard let binary else { throw ClaudeError(message: "Claude Code isn’t installed") }
        let resume = FileManager.default.fileExists(atPath: Self.file(for: session).path)
        let conversation = ClaudeSession(
            id: session, binary: binary, resume: resume,
            emit: { [weak self] event in
                guard let self else { return }
                AgentBackendSink.event(self.harness, session, event)
            },
            reportModel: { [weak self] model in
                self?.reportedModel = model
                self?.refreshModelState()
            },
            finished: { [weak self] in
                // Claude Code titles conversations in its session file.
                Task {
                    if let title = await Self.title(of: session) {
                        AgentBackendSink.event(.claudeCode, session, .title(title))
                    }
                    _ = self
                }
            },
            exited: { [weak self] in
                if self?.live[session]?.isRunning == false { self?.live[session] = nil }
            }
        )
        try conversation.launch()
        live[session] = conversation
        return conversation
    }

    // MARK: History (Claude Code's session files)

    nonisolated static var projectDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        let path = home.appendingPathComponent("CommandSpace/workspace").path
        let encoded = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return config.appendingPathComponent("projects").appendingPathComponent(encoded)
    }

    nonisolated static func file(for session: String) -> URL {
        projectDirectory.appendingPathComponent("\(session).jsonl")
    }

    func listSessions() async -> [AgentSessionSummary] { await Self.history() }

    /// Conversations Claude Code ran in Space's workspace (no process needed to list them).
    nonisolated static func history() async -> [AgentSessionSummary] {
        await Task.detached {
            let dir = Self.projectDirectory
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]) else { return [] }
            return files.filter { $0.pathExtension == "jsonl" }.compactMap { url -> AgentSessionSummary? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let id = url.deletingPathExtension().lastPathComponent
                guard let info = Self.summary(of: url) else { return nil }
                return AgentSessionSummary(id: id, harness: .claudeCode, title: info.title,
                                           created: values?.creationDate ?? .distantPast,
                                           updated: values?.contentModificationDate ?? .distantPast)
            }
        }.value
    }

    func snapshot(of session: String) async -> AgentSnapshot? {
        let items = await Task.detached { Self.transcript(of: Self.file(for: session)) }.value
        let conversation = live[session]
        return AgentSnapshot(items: items ?? [], permissions: conversation?.openPermissions ?? [],
                             busy: conversation?.isBusy ?? false, title: await Self.title(of: session))
    }

    func delete(_ session: String) async {
        live[session]?.terminate()
        live[session] = nil
        try? FileManager.default.trashItem(at: Self.file(for: session), resultingItemURL: nil)
    }

    nonisolated static func title(of session: String) async -> String? {
        await Task.detached { summary(of: file(for: session))?.title }.value
    }

    private nonisolated static func entries(of url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The user's own words in a user entry (not tool results, slash commands or reminders).
    private nonisolated static func spokenText(_ entry: [String: Any]) -> String? {
        guard entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return nil }
        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        guard let raw = text else { return nil }
        let said = SpaceWorkspace.stripContext(raw)
        if said.isEmpty || said.hasPrefix("<") { return nil }
        return said
    }

    private nonisolated static func summary(of url: URL) -> (title: String, prompts: Int)? {
        var aiTitle: String?
        var first: String?
        var prompts = 0
        for entry in entries(of: url) {
            switch entry["type"] as? String {
            case "ai-title": aiTitle = entry["aiTitle"] as? String ?? aiTitle
            case "summary": aiTitle = aiTitle ?? entry["summary"] as? String
            case "user":
                if let said = spokenText(entry) {
                    prompts += 1
                    if first == nil { first = said }
                }
            default: break
            }
        }
        guard prompts > 0 else { return nil }
        return (aiTitle ?? String((first ?? "").prefix(80)), prompts)
    }

    nonisolated static func transcript(of url: URL) -> [AgentItem]? {
        let entries = entries(of: url)
        guard !entries.isEmpty else { return nil }
        var items: [AgentItem] = []
        var toolIndex: [String: Int] = [:]
        for entry in entries where entry["isSidechain"] as? Bool != true {
            let uuid = entry["uuid"] as? String ?? UUID().uuidString
            switch entry["type"] as? String {
            case "user":
                if let said = spokenText(entry) {
                    items.append(AgentItem(id: uuid, kind: .user, text: said))
                } else if let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        guard let id = block["tool_use_id"] as? String, let index = toolIndex[id],
                              case .tool(let name, _) = items[index].kind else { continue }
                        let failed = block["is_error"] as? Bool == true
                        items[index].kind = .tool(name: name, status: failed ? "error" : "completed")
                        if failed, let line = ClaudeSession.resultText(block).split(separator: "\n").first {
                            items[index].text += "\n" + line
                        }
                    }
                }
            case "assistant":
                let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for (n, block) in blocks.enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if !text.isEmpty { items.append(AgentItem(id: "\(uuid):\(n)", kind: .assistant, text: text)) }
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "tool"
                        toolIndex[id] = items.count
                        items.append(AgentItem(id: id, kind: .tool(name: ClaudeSession.toolName(name), status: "completed"),
                                               text: ClaudeSession.summary(of: block["input"] as? [String: Any] ?? [:]),
                                               callID: id))
                    default: break
                    }
                }
            default: break
            }
        }
        return items
    }
}

// MARK: - One conversation's process

@MainActor
final class ClaudeSession {
    let id: String
    private let process: JSONLineProcess
    private let emit: (AgentEvent) -> Void
    private let reportModel: (String) -> Void
    private let finished: () -> Void
    private let exited: () -> Void

    private(set) var isBusy = false
    private var currentMessage = ""
    private var textIDs: [String: [String]] = [:]
    private var tools: [String: (name: String, summary: String)] = [:]
    private var requests: [String: (permission: AgentPermission, input: [String: Any], suggestions: [[String: Any]])] = [:]
    private var idleTask: Task<Void, Never>?
    private var nextRequest = 0

    var isRunning: Bool { process.isRunning }
    var openPermissions: [AgentPermission] { requests.values.map(\.permission) }

    init(id: String, binary: String, resume: Bool,
         emit: @escaping (AgentEvent) -> Void, reportModel: @escaping (String) -> Void,
         finished: @escaping () -> Void, exited: @escaping () -> Void) {
        self.id = id
        self.emit = emit
        self.reportModel = reportModel
        self.finished = finished
        self.exited = exited
        var arguments = [
            "-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default",
            "--append-system-prompt", SpaceWorkspace.instructions,
        ]
        arguments += resume ? ["--resume", id] : ["--session-id", id]
        let model = Defaults[.claudeModel]
        if !model.isEmpty { arguments += ["--model", model] }
        var receive: (([String: Any]) -> Void)?
        var exit: ((Int32, String) -> Void)?
        process = JSONLineProcess(
            executable: binary, arguments: arguments, environment: HarnessEnvironment.claude(binary: binary),
            directory: SpaceWorkspace.url,
            onMessage: { receive?($0) }, onExit: { exit?($0, $1) })
        receive = { [weak self] in self?.receive($0) }
        exit = { [weak self] status, stderr in self?.processExited(status: status, stderr: stderr) }
    }

    func launch() throws {
        try process.launch()
        control(["subtype": "initialize"])
    }

    func send(_ text: String) {
        idleTask?.cancel()
        isBusy = true
        process.send(["type": "user", "message": ["role": "user", "content": text]])
    }

    func interrupt() { control(["subtype": "interrupt"]) }

    func terminate() {
        idleTask?.cancel()
        process.terminate()
    }

    func reply(to requestID: String, with reply: PermissionReply) {
        guard let request = requests.removeValue(forKey: requestID) else { return }
        var response: [String: Any]
        switch reply {
        case .once:
            response = ["behavior": "allow", "updatedInput": request.input]
        case .always:
            // Remember for this conversation only, not in the user's Claude Code settings.
            let rules = request.suggestions.map { suggestion -> [String: Any] in
                var copy = suggestion
                copy["destination"] = "session"
                return copy
            }
            response = ["behavior": "allow", "updatedInput": request.input, "updatedPermissions": rules]
        case .reject:
            response = ["behavior": "deny", "message": "The user declined this action."]
        }
        process.send(["type": "control_response",
                      "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    private func control(_ request: [String: Any]) {
        nextRequest += 1
        process.send(["type": "control_request", "request_id": "cs-\(id.prefix(8))-\(nextRequest)", "request": request])
    }

    // MARK: Messages

    private func receive(_ message: [String: Any]) {
        // Ignore what subagents do; only the main conversation shows.
        if message["parent_tool_use_id"] is String { return }
        switch message["type"] as? String {
        case "system":
            switch message["subtype"] as? String {
            case "init": if let model = message["model"] as? String { reportModel(model) }
            case "status": if message["status"] as? String == "requesting" { emit(.step) }
            default: break
            }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "message_start":
                currentMessage = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
            case "content_block_start":
                if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                    let id = "\(currentMessage):\(event["index"] as? Int ?? 0)"
                    textIDs[currentMessage, default: []].append(id)
                }
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                    emit(.delta(id: "\(currentMessage):\(event["index"] as? Int ?? 0)", text: text))
                }
            default: break
            }
        case "assistant":
            guard let body = message["message"] as? [String: Any] else { return }
            let messageID = body["id"] as? String ?? currentMessage
            for block in body["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    var queue = textIDs[messageID] ?? []
                    let id = queue.isEmpty ? "\(messageID):\(UUID().uuidString)" : queue.removeFirst()
                    textIDs[messageID] = queue
                    emit(.item(AgentItem(id: id, kind: .assistant, text: block["text"] as? String ?? "")))
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = Self.toolName(block["name"] as? String ?? "tool")
                    let summary = Self.summary(of: block["input"] as? [String: Any] ?? [:])
                    tools[id] = (name, summary)
                    emit(.item(AgentItem(id: id, kind: .tool(name: name, status: "running"), text: summary, callID: id)))
                default: break
                }
            }
        case "user":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let tool = tools[id] else { continue }
                let failed = block["is_error"] as? Bool == true
                var text = tool.summary
                if failed, let line = Self.resultText(block).split(separator: "\n").first {
                    text += text.isEmpty ? String(line) : "\n" + line
                }
                emit(.item(AgentItem(id: id, kind: .tool(name: tool.name, status: failed ? "error" : "completed"),
                                     text: text, callID: id)))
            }
        case "control_request":
            handleControl(message)
        case "rate_limit_event":
            let info = message["rate_limit_info"] as? [String: Any]
            if info?["status"] as? String == "rejected" {
                var text = "You’ve reached your Claude usage limit"
                if let resets = info?["resetsAt"] as? Double {
                    text += "; it resets " + Date(timeIntervalSince1970: resets).formatted(date: .omitted, time: .shortened)
                }
                emit(.error(text + "."))
            }
        case "result":
            isBusy = false
            if message["is_error"] as? Bool == true || (message["subtype"] as? String).map({ $0 != "success" }) == true {
                let text = (message["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (message["errors"] as? [String])?.first
                    ?? "Claude Code stopped: \(message["subtype"] as? String ?? "error")"
                if message["subtype"] as? String != "error_during_execution" || !text.contains("interrupt") {
                    emit(.error(text))
                }
            }
            let usage = message["usage"] as? [String: Any]
            if let tokens = usage?["output_tokens"] as? Int, tokens > 0 {
                let seconds = (message["duration_api_ms"] as? Double).map { $0 / 1000 }
                emit(.generated(tokens: tokens, seconds: seconds))
            }
            emit(.busy(false))
            finished()
            scheduleIdleExit()
        default:
            break
        }
    }

    private func handleControl(_ message: [String: Any]) {
        guard let requestID = message["request_id"] as? String,
              let request = message["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool" else {
            process.send(["type": "control_response",
                          "response": ["subtype": "error", "request_id": requestID, "error": "Not supported by Command Space"]])
            return
        }
        let tool = request["tool_name"] as? String ?? "tool"
        let input = request["input"] as? [String: Any] ?? [:]
        var pattern = Self.summary(of: input)
        if pattern.isEmpty { pattern = request["description"] as? String ?? tool }
        let permission = AgentPermission(
            id: requestID, sessionID: id, permission: Self.toolName(tool), patterns: [pattern],
            callID: request["tool_use_id"] as? String)
        requests[requestID] = (permission, input, request["permission_suggestions"] as? [[String: Any]] ?? [])
        emit(.permission(permission))
    }

    private func scheduleIdleExit() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, !self.isBusy, self.requests.isEmpty else { return }
            self.process.terminate()
        }
    }

    private func processExited(status: Int32, stderr: String) {
        idleTask?.cancel()
        for requestID in requests.keys { emit(.permissionResolved(requestID)) }
        requests = [:]
        if isBusy {
            isBusy = false
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(status)"
            emit(.error("Claude Code stopped: \(tail)"))
            emit(.busy(false))
        }
        exited()
    }

    // MARK: Formatting

    nonisolated static func toolName(_ name: String) -> String {
        switch name {
        case "Bash": return "bash"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit"
        case "Read": return "read"
        case "WebFetch": return "webfetch"
        case "WebSearch": return "websearch"
        case "Glob", "Grep": return "search"
        default:
            if name.hasPrefix("mcp__") {
                return name.dropFirst(5).replacingOccurrences(of: "__", with: ".")
            }
            return name.lowercased()
        }
    }

    nonisolated static func summary(of input: [String: Any]) -> String {
        let value = (input["command"] as? String)
            ?? (input["file_path"] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? (input["url"] as? String)
            ?? (input["query"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["description"] as? String)
        return value ?? ""
    }

    nonisolated static func resultText(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        return (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
