//
//  AgentManager.swift
//  Command Space
//
//  System Two: talks to a local `opencode serve` instance (the agent harness) over HTTP + SSE.
//
//  Conversations are threads. Each `AgentThread` is one opencode session (created on its first
//  agent turn) with its own transcript, approvals and live activity. `AgentManager` owns the
//  connection, routes the server's event stream to the right thread, and decides which thread
//  a new request belongs to:
//    • opening Command Space, ⌥Space, push-to-talk and whistles start a new thread,
//    • typing into an open conversation (panel or window) continues it,
//    • once System Two has answered in a thread, follow-ups skip System One and go to the agent.
//

import AppKit
import Combine
import Defaults
import Foundation

extension Defaults.Keys {
    static let agentServerURL = Key<String>("agentServerURL", default: "http://127.0.0.1:4096")
    static let agentSessionID = Key<String>("agentSessionID", default: "")
    static let agentModelURL = Key<String>("agentModelURL", default: "http://127.0.0.1:8081")
}

extension Notification.Name {
    static let agentNeedsAttention = Notification.Name("agentNeedsAttention")
    /// A request made without Command Space open (e.g. by voice) finished; userInfo["dwell"] is seconds to show it.
    static let agentShowResult = Notification.Name("agentShowResult")
}

struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String, status: String)
        case quick(icon: String)
        case error
    }

    let id: String
    var kind: Kind
    var text: String
    var callID: String? = nil
}

struct AgentPermission: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let callID: String?
}

enum AgentModelState: Equatable {
    case unknown
    case ready(String)
    case asleep(String)
    /// A hosted model selected in Settings; the local server's state doesn't matter.
    case cloud(provider: String, model: String)
    case unreachable
}

/// Live model state reported by the gemma-tools-proxy at GET /notch/status.
struct ModelLiveStatus: Decodable, Equatable {
    struct LastRun: Decodable, Equatable {
        let kind: String
        let promptTokens: Int
        let cached: Int
        let prefillTps: Double
        let genTokens: Int
        let genTps: Double
        let durationMs: Double
        let endedAt: Double
    }

    let phase: String            // idle | waking | prefill | generating
    let kind: String
    let promptTotal: Int
    let promptCached: Int
    let promptProcessed: Int
    let prefillTps: Double
    let genTokens: Int
    let genTps: Double
    let elapsedMs: Double
    let last: LastRun?
}

struct AgentRetry: Equatable {
    let attempt: Int
    let message: String
    let next: Date?
}

/// Shown when the done-check thinks a finished task didn't actually get done.
struct AgentFollowUp: Equatable {
    enum Kind: String { case failed, incomplete, looping }
    let kind: Kind
    let itemID: String
    let request: String
}

/// Stats shown under a finished answer.
struct AgentRunSummary: Equatable {
    let duration: TimeInterval
    let steps: Int
    let tools: Int
    let genTokens: Int
    let genTps: Double?
}

enum AgentConnection: Equatable {
    case connecting
    case connected
    case offline(String)
}

/// A past or present conversation, as listed by the server.
struct AgentSessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let created: Date
    var updated: Date

    /// opencode names threads it never titled "New session - <timestamp>".
    var displayTitle: String {
        if title.isEmpty || title.hasPrefix("New session") {
            return "Untitled conversation · " + created.formatted(.dateTime.month(.abbreviated).day())
        }
        return title
    }
}

// MARK: - Thread

@MainActor
final class AgentThread: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    /// The opencode session; empty until the first request that goes to the agent.
    @Published private(set) var sessionID: String
    @Published private(set) var items: [AgentItem] = []
    @Published private(set) var permissions: [AgentPermission] = []
    @Published private(set) var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            isBusy ? beginTask() : finishTask()
        }
    }
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false

    // Live activity for the current task.
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var stepCount = 0
    @Published private(set) var retry: AgentRetry?
    @Published private(set) var modelStatus: ModelLiveStatus?
    @Published private(set) var toolStartedAt: [String: Date] = [:]
    /// Keyed by the id of the last assistant item of each finished task.
    @Published private(set) var runSummaries: [String: AgentRunSummary] = [:]
    @Published private(set) var followUp: AgentFollowUp?
    /// "Make this instant?" offer for the last finished task (System 2 teaches System 1).
    @Published private(set) var learnOffer: LearnCandidate?

    private var roles: [String: String] = [:]  // messageID -> role
    private var taskToolIDs: Set<String> = []
    private var taskGenTokens = 0
    private var taskGenSeconds: Double = 0
    private var lastCountedRun: Double = 0
    private var statusTask: Task<Void, Never>?
    private var showResultWhenDone = false
    private(set) var lastActivityAt = Date()

    private var manager: AgentManager { .shared }

    init(sessionID: String = "", title: String = "") {
        self.sessionID = sessionID
        self.title = title
    }

    var isEmpty: Bool { items.isEmpty && !isBusy && sessionID.isEmpty }

    /// System Two has taken this conversation over: everything said here goes to the agent.
    var ownedBySystemTwo: Bool { !sessionID.isEmpty }

    var displayTitle: String {
        if !title.isEmpty, !title.hasPrefix("New session") { return title }
        return items.first(where: { $0.kind == .user })?.text ?? "New conversation"
    }

    // MARK: Requests

    /// - Parameter showResult: show Command Space with the outcome when done (for requests
    ///   made without it open, like push-to-talk).
    func send(_ text: String, showResult: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SpaceMarkEvents.fire(.send)
        lastActivityAt = Date()
        Task {
            followUp = nil
            learnOffer = nil
            // Typed requests: capture the app behind Command Space (no ⌘C fallback, the panel has
            // keyboard focus). Push-to-talk already captured when the key went down.
            if !showResult { ContextCapture.shared.begin(allowCopyFallback: false) }
            // System One handles simple requests instantly, but only until System Two has the
            // conversation: after that, "the Command Space app" is an answer, not a command.
            if !ownedBySystemTwo {
                if showResult { manager.setRoutingVoice(true) }
                let quick = await QuickActions.shared.tryHandle(trimmed)
                manager.setRoutingVoice(false)
                if let quick {
                    items.append(AgentItem(id: UUID().uuidString, kind: .user, text: trimmed))
                    items.append(AgentItem(id: UUID().uuidString, kind: .quick(icon: quick.icon), text: quick.label))
                    if showResult { manager.flashResult(icon: quick.icon, label: quick.label) }
                    return
                }
            }
            showResultWhenDone = showResult
            do {
                if sessionID.isEmpty {
                    sessionID = try await manager.createSession()
                    manager.register(self)
                }
                isBusy = true
                var parts: [[String: Any]] = [["type": "text", "text": trimmed]]
                // "Summarize this", "move these": give the agent what the user is looking at.
                // Sent as a hidden (synthetic) part so the chat shows only what was said.
                let refers = QuickActions.shared.lastThisRefers
                if let screen = await ContextCapture.shared.context(maxWait: 0.3), screen.hasReferent,
                   (refers != nil && refers != "none") || (refers == nil && RequestParsing.mentionsOnScreen(trimmed)) {
                    parts.insert(["type": "text", "text": screen.promptBlock(focus: refers), "synthetic": true], at: 0)
                }
                var body: [String: Any] = ["parts": parts]
                let override = Defaults[.agentModelOverride]
                if let slash = override.firstIndex(of: "/") {
                    body["model"] = ["providerID": String(override[..<slash]),
                                     "modelID": String(override[override.index(after: slash)...])]
                }
                _ = try await manager.request("POST", "/session/\(sessionID)/prompt_async", body: body)
            } catch {
                isBusy = false
                appendError("Couldn't reach the agent: \(error.localizedDescription)")
                if showResult { showResultWhenDone = false; manager.announceResult(of: self, dwell: 6) }
            }
        }
    }

    func abort() {
        guard !sessionID.isEmpty else { return }
        Task { _ = try? await manager.request("POST", "/session/\(sessionID)/abort") }
    }

    /// reply: "once", "always" or "reject"
    func reply(to permission: AgentPermission, with reply: String) {
        permissions.removeAll { $0.id == permission.id }
        manager.permissionsChanged()
        Task {
            _ = try? await manager.request("POST", "/permission/\(permission.id)/reply", body: ["reply": reply])
        }
    }

    func command(for permission: AgentPermission) -> String {
        if let callID = permission.callID,
           let item = items.last(where: { $0.callID == callID }), !item.text.isEmpty {
            return item.text
        }
        let joined = permission.patterns.joined(separator: " | ")
        return joined.isEmpty ? permission.permission : joined
    }

    var runningTool: AgentItem? {
        items.last {
            if case .tool(_, let status) = $0.kind { return status == "running" || status == "pending" }
            return false
        }
    }

    func dismissFollowUp() { followUp = nil }

    func acceptLearnOffer() {
        guard let offer = learnOffer else { return }
        let action = LearnedActions.shared.learn(offer)
        learnOffer = nil
        manager.flashResult(icon: "bolt.fill", label: "“\(action.title)” is now instant")
    }

    func dismissLearnOffer() { learnOffer = nil }

    // MARK: Activity

    private func beginTask() {
        if taskStartedAt == nil { taskStartedAt = Date() }
        stepCount = 0
        retry = nil
        taskToolIDs = []
        taskGenTokens = 0
        taskGenSeconds = 0
        lastCountedRun = Date().timeIntervalSince1970 * 1000
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollModelStatus()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func finishTask() {
        lastActivityAt = Date()
        statusTask?.cancel()
        statusTask = nil
        Task { await pollModelStatus() }  // pick up the final generation stats
        if let started = taskStartedAt,
           let last = items.last(where: { $0.kind == .assistant }) {
            runSummaries[last.id] = AgentRunSummary(
                duration: Date().timeIntervalSince(started),
                steps: max(stepCount, 1),
                tools: taskToolIDs.count,
                genTokens: taskGenTokens,
                genTps: taskGenSeconds > 0 ? Double(taskGenTokens) / taskGenSeconds : nil
            )
        }
        taskStartedAt = nil
        retry = nil
        modelStatus = nil
        Task { await checkDone() }
        if DecisionEngine.shared.decisionsAvailable, Defaults[.jevInstantActions] {
            learnOffer = LearnedActions.shared.candidate(from: items)
        }
        if let last = items.last, last.kind == .assistant { SpaceMarkEvents.fire(.success) }
        if showResultWhenDone {
            showResultWhenDone = false
            let reply = items.last(where: { $0.kind == .assistant || $0.kind == .error })?.text ?? ""
            manager.announceResult(of: self, dwell: min(12, 5 + Double(reply.count) * 0.04))
        }
        manager.threadChanged(self)
    }

    /// Asks Jev whether the last task actually finished. Jev-only; skipped offline.
    private func checkDone() async {
        guard Defaults[.jevDoneCheck], DecisionEngine.shared.decisionsAvailable,
              let userIndex = items.lastIndex(where: { $0.kind == .user }),
              let reply = items.last(where: { $0.kind == .assistant }),
              let replyIndex = items.firstIndex(of: reply), replyIndex > userIndex else { return }
        let request = items[userIndex].text
        let tools: [[String: String]] = items[userIndex...].compactMap {
            guard case .tool(let name, let status) = $0.kind else { return nil }
            return ["tool": name, "status": status, "input": String($0.text.prefix(160))]
        }
        let state: [String: Any] = [
            "user_request": String(request.prefix(500)),
            "tool_calls": tools,
            "final_reply": String(reply.text.prefix(600)),
        ]
        guard let result = await DecisionEngine.shared.decide(
            state: state,
            questions: [
                ("outcome", .choice("How did the assistant's attempt at the user's request end?", [
                    ("done", "The request was carried out and the reply confirms the result"),
                    ("needs_input", "The assistant asked the user a question or is waiting for confirmation"),
                    ("failed", "A step failed or the reply says it could not do it"),
                    ("incomplete", "The assistant stopped partway without finishing or explaining why"),
                ])),
                ("looping", .noul("The assistant repeated the same tool call several times without making progress")),
            ],
            timeout: 3
        ), items.last?.id == reply.id, !isBusy else { return }

        let outcome = result["outcome"]?.choice ?? "done"
        let confident = (result["outcome"]?.confidence ?? 0) >= 0.7
        if (result["looping"]?.probability ?? 0) >= 0.7 {
            followUp = AgentFollowUp(kind: .looping, itemID: reply.id, request: request)
        } else if confident, let kind = AgentFollowUp.Kind(rawValue: outcome) {
            followUp = AgentFollowUp(kind: kind, itemID: reply.id, request: request)
        }
    }

    private func pollModelStatus() async {
        guard let url = URL(string: Defaults[.agentModelURL] + "/notch/status") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let status = try? JSONDecoder().decode(ModelLiveStatus.self, from: data) else { return }
        if let last = status.last, last.kind == "agent", last.endedAt > lastCountedRun {
            lastCountedRun = last.endedAt
            taskGenTokens += last.genTokens
            if last.genTps > 0 { taskGenSeconds += Double(last.genTokens) / last.genTps }
        }
        if isBusy { modelStatus = status }
    }

    // MARK: Server state

    /// Rebuilds the transcript, approvals and busy state from the server.
    func load() async {
        guard !sessionID.isEmpty else { return }
        isLoading = items.isEmpty
        defer { isLoading = false }
        if let data = try? await manager.request("GET", "/session/\(sessionID)/message"),
           let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var rebuilt: [AgentItem] = []
            roles = [:]
            for message in messages {
                guard let info = message["info"] as? [String: Any],
                      let mid = info["id"] as? String else { continue }
                roles[mid] = info["role"] as? String
                for part in message["parts"] as? [[String: Any]] ?? [] {
                    if let item = makeItem(from: part) { rebuilt.append(item) }
                }
            }
            // Keep instant-action rows that only ever lived on this Mac.
            let local = items.filter { if case .quick = $0.kind { return true }; return false }
            items = local.isEmpty ? rebuilt : rebuilt + local
        }
        if let data = try? await manager.request("GET", "/permission"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            permissions = list.compactMap(Self.makePermission).filter { $0.sessionID == sessionID }
        }
        if let data = try? await manager.request("GET", "/session/status"),
           let statuses = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let mine = statuses[sessionID] as? [String: Any]
            isBusy = (mine?["type"] as? String) == "busy"
        }
        manager.permissionsChanged()
    }

    func handle(type: String, props: [String: Any]) {
        switch type {
        case "message.updated":
            if let info = props["info"] as? [String: Any], let id = info["id"] as? String {
                roles[id] = info["role"] as? String
                if let error = info["error"] as? [String: Any] {
                    let data = error["data"] as? [String: Any]
                    let message = data?["message"] as? String ?? error["name"] as? String ?? "Unknown error"
                    if (error["name"] as? String) != "MessageAbortedError" { appendError(message) }
                }
            }
        case "message.part.updated":
            guard let part = props["part"] as? [String: Any] else { return }
            if part["type"] as? String == "step-start", isBusy { stepCount += 1 }
            if let item = makeItem(from: part) {
                if case .tool(_, let status) = item.kind {
                    if isBusy { taskToolIDs.insert(item.id) }
                    if status == "running", toolStartedAt[item.id] == nil { toolStartedAt[item.id] = Date() }
                }
                upsert(item)
            }
        case "message.part.delta":
            guard (props["field"] as? String) == "text",
                  let partID = props["partID"] as? String,
                  let delta = props["delta"] as? String else { return }
            if let index = items.firstIndex(where: { $0.id == partID }) {
                items[index].text += delta
            } else {
                let role = roles[props["messageID"] as? String ?? ""]
                items.append(AgentItem(id: partID, kind: role == "user" ? .user : .assistant, text: delta))
            }
        case "session.status":
            let info = props["status"] as? [String: Any]
            let status = info?["type"] as? String
            isBusy = status == "busy" || status == "retry"
            if status == "retry" {
                let next = (info?["next"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                retry = AgentRetry(attempt: info?["attempt"] as? Int ?? 1,
                                   message: info?["message"] as? String ?? "Retrying", next: next)
            } else {
                retry = nil
            }
        case "session.idle":
            isBusy = false
        case "session.updated":
            if let info = props["info"] as? [String: Any], let title = info["title"] as? String {
                self.title = title
            }
        case "session.error":
            if let error = props["error"] as? [String: Any], (error["name"] as? String) != "MessageAbortedError" {
                let data = error["data"] as? [String: Any]
                if (error["name"] as? String)?.contains("ModelNotFound") == true {
                    appendError("The model “\(Defaults[.agentModelOverride])” isn't available. Choose another in Settings → System Two.")
                } else {
                    appendError(data?["message"] as? String ?? error["name"] as? String ?? "Agent error")
                }
                isBusy = false
            }
        case "permission.asked":
            if let permission = Self.makePermission(props), !permissions.contains(where: { $0.id == permission.id }) {
                permissions.append(permission)
                SpaceMarkEvents.fire(.attention)
                manager.permissionAsked(in: self)
            }
        case "permission.replied":
            if let requestID = props["requestID"] as? String {
                permissions.removeAll { $0.id == requestID }
                manager.permissionsChanged()
            }
        default:
            break
        }
    }

    private func makeItem(from part: [String: Any]) -> AgentItem? {
        guard let id = part["id"] as? String, let type = part["type"] as? String else { return nil }
        let role = roles[part["messageID"] as? String ?? ""]
        switch type {
        case "text":
            if part["synthetic"] as? Bool == true { return nil }
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

    private func upsert(_ item: AgentItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            // Deltas may have already filled in text that a stale part update would erase.
            if item.text.isEmpty, case .assistant = item.kind { return }
            items[index] = item
        } else {
            items.append(item)
        }
    }

    func appendError(_ message: String) {
        SpaceMarkEvents.fire(.error)
        items.append(AgentItem(id: UUID().uuidString, kind: .error, text: message))
    }
}

// MARK: - Manager

@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager()

    /// The conversation Command Space's panel shows.
    @Published private(set) var current = AgentThread() {
        didSet { observeCurrent() }
    }
    @Published private(set) var connection: AgentConnection = .connecting
    @Published private(set) var modelState: AgentModelState = .unknown
    /// Past conversations on the server, most recent first.
    @Published private(set) var sessions: [AgentSessionSummary] = []
    /// Brief result of an instant action, shown in the live pill.
    @Published private(set) var quickResult: (id: UUID, icon: String, label: String)?
    /// True while a spoken request is being routed (keeps the listening strip up, avoiding a flicker).
    @Published private(set) var isRoutingVoice = false

    /// Threads with a session, so server events can find them.
    private var threads: [String: AgentThread] = [:]
    private var quickResultTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var holdingPanel = false

    private var baseURL: URL { URL(string: Defaults[.agentServerURL]) ?? URL(string: "http://127.0.0.1:4096")! }

    private init() {
        observeCurrent()
        start()
    }

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in await self?.runEventLoop() }
    }

    // MARK: The current thread (what the panel shows)

    var items: [AgentItem] { current.items }
    var permissions: [AgentPermission] { current.permissions }
    var isBusy: Bool { current.isBusy }
    var taskStartedAt: Date? { current.taskStartedAt }
    var stepCount: Int { current.stepCount }
    var runningTool: AgentItem? { current.runningTool }

    /// Every thread that's alive in this app (the panel's, the window's, ones working in the background).
    var liveThreads: [AgentThread] {
        var list = Array(threads.values)
        if !list.contains(where: { $0 === current }) { list.append(current) }
        if let shown = ThreadWindowController.shared.thread, !list.contains(where: { $0 === shown }) { list.append(shown) }
        return list
    }

    var anyBusy: Bool { liveThreads.contains { $0.isBusy } }
    var anyPermissions: Bool { liveThreads.contains { !$0.permissions.isEmpty } }

    /// The thread most worth showing when nothing else is: waiting for approval, then working.
    var mostRelevantThread: AgentThread? {
        liveThreads.first { !$0.permissions.isEmpty }
            ?? liveThreads.filter(\.isBusy).max { $0.lastActivityAt < $1.lastActivityAt }
    }

    private var threadObservers: [UUID: AnyCancellable] = [:]

    private func observeCurrent() {
        observe(current)
    }

    /// Changes in any live thread (not just the panel's) reach views observing the manager,
    /// e.g. the live pill showing a thread working in the background.
    func observe(_ thread: AgentThread) {
        guard threadObservers[thread.id] == nil else { return }
        threadObservers[thread.id] = thread.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// A clean slate for the panel (the previous thread stays in history and keeps running).
    func newThread() {
        guard !current.isEmpty else { return }
        current = AgentThread()
    }

    /// Shows `thread` in the panel.
    func makeCurrent(_ thread: AgentThread) {
        guard thread !== current else { return }
        current = thread
    }

    /// The live thread for a session, or one loaded from the server.
    func thread(forSession id: String) -> AgentThread {
        if let existing = threads[id] { return existing }
        let title = sessions.first { $0.id == id }?.title ?? ""
        let thread = AgentThread(sessionID: id, title: title)
        threads[id] = thread
        observe(thread)
        Task { await thread.load() }
        return thread
    }

    func register(_ thread: AgentThread) {
        threads[thread.sessionID] = thread
        observe(thread)
        Task { await refreshSessions() }
    }

    func threadChanged(_ thread: AgentThread) {
        Task { await refreshSessions() }
    }

    // MARK: Routing new requests

    /// Typed into the panel: continues whatever the panel shows.
    func send(_ text: String, showResult: Bool = false) {
        current.send(text, showResult: showResult)
    }

    /// Push-to-talk and whistle commands. Continue the conversation you're looking at (the
    /// window if it's in front, or the panel's open conversation); otherwise start a new thread.
    func sendFromVoice(_ text: String) {
        if ThreadWindowController.shared.isKey, let thread = ThreadWindowController.shared.thread {
            thread.send(text, showResult: false)
            return
        }
        let panel = CommandPanelController.shared
        if panel.isVisible, panel.model.mode == .agent, !current.isEmpty {
            current.send(text, showResult: true)
            return
        }
        current = AgentThread()
        current.send(text, showResult: true)
    }

    /// Ambient nudges start their own thread.
    func startThread(with text: String) {
        current = AgentThread()
        current.send(text)
    }

    func setRoutingVoice(_ on: Bool) { isRoutingVoice = on }

    // MARK: Showing results and approvals

    func announceResult(of thread: AgentThread, dwell: TimeInterval) {
        // Already on screen in the conversation window.
        if ThreadWindowController.shared.thread === thread, ThreadWindowController.shared.isVisible { return }
        makeCurrent(thread)
        NotificationCenter.default.post(name: .agentShowResult, object: nil, userInfo: ["dwell": dwell])
    }

    func permissionAsked(in thread: AgentThread) {
        if ThreadWindowController.shared.thread === thread, ThreadWindowController.shared.isVisible {
            ThreadWindowController.shared.bringForward()
        } else {
            makeCurrent(thread)
            NotificationCenter.default.post(name: .agentNeedsAttention, object: nil)
        }
        permissionsChanged()
    }

    /// Keep Command Space open while an approval outside the conversation window is waiting.
    func permissionsChanged() {
        let windowThread = ThreadWindowController.shared.isVisible ? ThreadWindowController.shared.thread : nil
        let shouldHold = liveThreads.contains { $0 !== windowThread && !$0.permissions.isEmpty }
        guard shouldHold != holdingPanel else { return }
        holdingPanel = shouldHold
        if shouldHold, let waiting = liveThreads.first(where: { $0 !== windowThread && !$0.permissions.isEmpty }) {
            makeCurrent(waiting)
        }
        CommandPanelController.shared.setHold("approval", shouldHold)
    }

    /// Briefly shows a result in the live pill (instant actions, timers).
    func flashResult(icon: String, label: String, duration: TimeInterval = 2.6) {
        SpaceMarkEvents.fire(icon.contains("exclamationmark") || icon.contains("xmark") ? .error : .success)
        let id = UUID()
        quickResult = (id, icon, label)
        quickResultTask?.cancel()
        quickResultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.quickResult?.id == id else { return }
            self?.quickResult = nil
        }
    }

    // MARK: Shell (no model, no session)

    /// Runs a command and returns its output, or nil on failure.
    func runShellCapturing(_ command: String) async -> String? {
        await Shell.run(command)
    }

    func runShell(_ command: String) async {
        if await Shell.run(command) == nil {
            flashResult(icon: "exclamationmark.triangle.fill", label: "Command failed")
        }
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

    // MARK: Sessions

    func createSession() async throws -> String {
        let data = try await request("POST", "/session", body: [String: Any]())
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    func refreshSessions() async {
        guard let data = try? await request("GET", "/session"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        sessions = list.compactMap { info -> AgentSessionSummary? in
            guard let id = info["id"] as? String, info["parentID"] == nil else { return nil }
            let time = info["time"] as? [String: Any]
            let created = (time?["created"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let updated = (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? created
            return AgentSessionSummary(id: id, title: info["title"] as? String ?? "", created: created, updated: updated)
        }
        .sorted { $0.updated > $1.updated }
    }

    func deleteSession(_ id: String) {
        Task {
            _ = try? await request("DELETE", "/session/\(id)")
            threads[id] = nil
            sessions.removeAll { $0.id == id }
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
                await refreshSessions()
                for thread in liveThreads where !thread.sessionID.isEmpty { await thread.load() }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    dispatch(event)
                }
                throw URLError(.networkConnectionLost)
            } catch {
                connection = .offline("Agent offline – is opencode serve running on \(baseURL.host ?? ""):\(baseURL.port ?? 0)?")
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
        if type == "session.updated", let info = props["info"] as? [String: Any], let id = info["id"] as? String,
           let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = info["title"] as? String ?? sessions[index].title
            sessions[index].updated = Date()
        }
        guard let sessionID, let thread = threads[sessionID] else { return }
        thread.handle(type: type, props: props)
    }

    // MARK: - HTTP

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
