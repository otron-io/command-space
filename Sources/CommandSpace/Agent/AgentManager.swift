//
//  AgentManager.swift
//  Command Space
//
//  System Two: the agent, running on one of several harnesses (opencode, Codex, Claude Code;
//  see Harness.swift and the *Backend files).
//
//  Conversations are threads. Each `AgentThread` is one harness session (created on its first
//  agent turn) with its own transcript, approvals and live activity, and it stays on the harness
//  it started on. `AgentManager` owns the backends, routes their events to the right thread, and
//  decides which thread a new request belongs to:
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
    /// Set when the agent is asking to leave plan mode with this plan.
    var plan: String? = nil

    var isEdit: Bool { ["edit", "write", "patch", "multiedit", "apply_patch"].contains(permission.lowercased()) }
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

/// A past or present conversation, as listed by its harness.
struct AgentSessionSummary: Identifiable, Equatable {
    let id: String
    let harness: SystemTwoHarness
    var title: String
    let created: Date
    var updated: Date

    /// opencode names threads it never titled "New session - <timestamp>".
    var displayTitle: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.hasPrefix("New session") {
            return "Untitled conversation · " + created.formatted(.dateTime.month(.abbreviated).day())
        }
        return title
    }
}

// MARK: - Thread

@MainActor
final class AgentThread: ObservableObject, Identifiable {
    nonisolated let id = UUID()

    /// The harness session; empty until the first request that goes to the agent.
    @Published private(set) var sessionID: String
    /// The harness this conversation runs on. Fixed once it has a session.
    @Published private(set) var harness: SystemTwoHarness
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
    /// How much the agent may do without asking, for this conversation.
    @Published private(set) var mode: AgentMode
    /// The plan reply (in plan mode) that can be run with one click; keyed by its item id.
    @Published private(set) var planReadyItemID: String?

    /// The user picked a mode for this conversation (so it survives the harness being chosen).
    private var modeChosen = false
    private var taskToolIDs: Set<String> = []
    private var taskGenTokens = 0
    private var taskGenSeconds: Double = 0
    private var lastCountedRun: Double = 0
    private var statusTask: Task<Void, Never>?
    private var showResultWhenDone = false
    private(set) var lastActivityAt = Date()

    private var manager: AgentManager { .shared }
    private var backend: AgentBackend { manager.backend(harness) }

    init(sessionID: String = "", harness: SystemTwoHarness? = nil, title: String = "") {
        self.sessionID = sessionID
        let harness = harness ?? Defaults[.systemTwoHarness]
        self.harness = harness
        self.mode = harness.defaultMode
        self.title = title
    }

    // MARK: Mode

    func setMode(_ mode: AgentMode) {
        guard harness.modes.contains(mode), mode != self.mode else { return }
        self.mode = mode
        modeChosen = true
        if mode != .plan { planReadyItemID = nil }
        if !sessionID.isEmpty { backend.setMode(mode, for: sessionID) }
        // Approvals the new mode no longer needs are answered now.
        for permission in permissions where autoApproves(permission) {
            reply(to: permission, with: PermissionReply.once.rawValue)
        }
    }

    /// ⇧⇥: the next mode this harness offers.
    func cycleMode() {
        let modes = harness.modes
        guard let index = modes.firstIndex(of: mode) else { setMode(.ask); return }
        setMode(modes[(index + 1) % modes.count])
    }

    /// After a plan: switch to the harness's working mode and go.
    func runPlan() {
        planReadyItemID = nil
        setMode(harness.executionMode)
        send("Go ahead with the plan.")
    }

    func dismissPlan() { planReadyItemID = nil }

    /// Approvals Command Space answers itself because the mode says not to ask.
    /// (Harnesses with a native equivalent never send these in the first place.)
    private func autoApproves(_ permission: AgentPermission) -> Bool {
        guard permission.plan == nil else { return false }
        switch mode {
        case .fullAccess: return true
        case .acceptEdits: return permission.isEdit
        case .plan, .ask, .auto: return false
        }
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
            items.append(AgentItem(id: UUID().uuidString, kind: .user, text: trimmed))
            do {
                if sessionID.isEmpty {
                    // A fresh conversation goes to the harness chosen in Settings right now.
                    harness = Defaults[.systemTwoHarness]
                    if !modeChosen || !harness.modes.contains(mode) { mode = harness.defaultMode }
                    isBusy = true
                    sessionID = try await backend.createSession()
                    manager.register(self)
                }
                isBusy = true
                // "Summarize this", "move these": give the agent what the user is looking at,
                // sent so the chat shows only what was said.
                var context: String?
                let refers = QuickActions.shared.lastThisRefers
                if let screen = await ContextCapture.shared.context(maxWait: 0.3), screen.hasReferent,
                   (refers != nil && refers != "none") || (refers == nil && RequestParsing.mentionsOnScreen(trimmed)) {
                    context = screen.promptBlock(focus: refers)
                }
                planReadyItemID = nil
                try await backend.send(trimmed, context: context, mode: mode, to: sessionID)
            } catch {
                isBusy = false
                appendError("Couldn't reach \(harness.name): \(error.localizedDescription)")
                if showResult { showResultWhenDone = false; manager.announceResult(of: self, dwell: 6) }
            }
        }
    }

    func abort() {
        guard !sessionID.isEmpty else { return }
        backend.abort(sessionID)
    }

    /// reply: "once", "always" or "reject"
    func reply(to permission: AgentPermission, with reply: String) {
        permissions.removeAll { $0.id == permission.id }
        manager.permissionsChanged()
        backend.reply(to: permission, with: PermissionReply(rawValue: reply) ?? .reject)
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
        // Live prefill/generation progress only exists for the local model behind opencode.
        guard harness == .opencode else { return }
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
        if harness == .opencode { Task { await pollModelStatus() } }  // pick up the final generation stats
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
        if let last = items.last, last.kind == .assistant {
            SpaceMarkEvents.fire(.success)
            if mode == .plan, permissions.isEmpty { planReadyItemID = last.id; learnOffer = nil }
        }
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

    // MARK: Harness state

    /// Rebuilds the transcript, approvals and busy state from the harness.
    func load() async {
        guard !sessionID.isEmpty else { return }
        isLoading = items.isEmpty
        defer { isLoading = false }
        guard let snapshot = await backend.snapshot(of: sessionID) else { return }
        // A request sent while loading is newer than what the harness returned.
        if isBusy, !snapshot.busy, items.count > snapshot.items.count { return }
        // Keep instant-action rows that only ever lived on this Mac.
        let local = items.filter { if case .quick = $0.kind { return true }; return false }
        if !snapshot.items.isEmpty || items.allSatisfy({ if case .quick = $0.kind { return true }; return false }) {
            items = local.isEmpty ? snapshot.items : snapshot.items + local
        }
        permissions = snapshot.permissions
        isBusy = snapshot.busy
        if let title = snapshot.title, !title.isEmpty { self.title = title }
        manager.permissionsChanged()
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .item(let item):
            if case .tool(_, let status) = item.kind {
                if isBusy { taskToolIDs.insert(item.id) }
                if status == "running", toolStartedAt[item.id] == nil { toolStartedAt[item.id] = Date() }
            }
            upsert(item)
        case .delta(let id, let text):
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].text += text
            } else {
                items.append(AgentItem(id: id, kind: .assistant, text: text))
            }
        case .busy(let busy):
            isBusy = busy
        case .retry(let retry):
            self.retry = retry
        case .step:
            if isBusy { stepCount += 1 }
        case .title(let title):
            self.title = title
        case .error(let message):
            appendError(message)
        case .permission(let permission):
            guard !permissions.contains(where: { $0.id == permission.id }) else { return }
            if autoApproves(permission) {
                backend.reply(to: permission, with: .once)
                return
            }
            permissions.append(permission)
            SpaceMarkEvents.fire(.attention)
            manager.permissionAsked(in: self)
        case .permissionResolved(let id):
            permissions.removeAll { $0.id == id }
            manager.permissionsChanged()
        case .generated(let tokens, let seconds):
            taskGenTokens += tokens
            if let seconds, seconds > 0 { taskGenSeconds += seconds }
        case .mode(let mode):
            self.mode = mode
            if mode != .plan { planReadyItemID = nil }
        }
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
    /// Past conversations on every harness, most recent first.
    @Published private(set) var sessions: [AgentSessionSummary] = []
    /// Brief result of an instant action, shown in the live pill.
    @Published private(set) var quickResult: (id: UUID, icon: String, label: String)?
    /// True while a spoken request is being routed (keeps the listening strip up, avoiding a flicker).
    @Published private(set) var isRoutingVoice = false

    /// Threads with a session, so harness events can find them.
    private var threads: [String: AgentThread] = [:]
    private var backends: [SystemTwoHarness: AgentBackend] = [:]
    private var lastConnection: [SystemTwoHarness: AgentConnection] = [:]
    private var quickResultTask: Task<Void, Never>?
    private var holdingPanel = false
    private var harnessObserver: Defaults.Observation?

    private init() {
        AgentBackendSink.event = { [weak self] harness, session, event in
            self?.deliver(event, to: session, from: harness)
        }
        AgentBackendSink.changed = { [weak self] harness in self?.backendChanged(harness) }
        observeCurrent()
        harnessObserver = Defaults.observe(.systemTwoHarness, options: []) { [weak self] change in
            Task { @MainActor in self?.harnessSelected(change.newValue) }
        }
        start()
    }

    func start() {
        backend(activeHarness).start()
        // opencode keeps serving its old conversations even when another harness is chosen.
        backend(.opencode).start()
        Task { await refreshSessions() }
    }

    // MARK: Harnesses

    var activeHarness: SystemTwoHarness { Defaults[.systemTwoHarness] }

    /// The harness new conversations go to.
    var activeBackend: AgentBackend { backend(activeHarness) }
    var connection: AgentConnection { activeBackend.connection }
    var modelState: AgentModelState { activeBackend.modelState }

    func backend(_ harness: SystemTwoHarness) -> AgentBackend {
        if let existing = backends[harness] { return existing }
        let made: AgentBackend
        switch harness {
        case .opencode: made = OpencodeBackend()
        case .codex: made = CodexBackend()
        case .claudeCode: made = ClaudeBackend()
        }
        backends[harness] = made
        made.start()
        return made
    }

    var codexModels: [(id: String, name: String)] { (backends[.codex] as? CodexBackend)?.models ?? [] }

    /// Whether a harness still has a reason to run: it's selected, or a live conversation uses it.
    func wants(_ harness: SystemTwoHarness) -> Bool {
        activeHarness == harness || liveThreads.contains { $0.harness == harness && !$0.sessionID.isEmpty }
    }

    private func harnessSelected(_ harness: SystemTwoHarness) {
        backend(harness).start()
        backend(harness).refreshModelState()
        // An empty conversation in the panel switches with the setting.
        if current.isEmpty { current = AgentThread() }
        // Stop a CLI nobody uses any more (opencode is a separate service, left alone).
        for (other, backend) in backends where other != harness && other != .opencode && !wants(other) {
            backend.stop()
        }
        objectWillChange.send()
        Task { await refreshSessions() }
    }

    /// Restart a harness so it picks up changed settings (a different model, a new login).
    func restart(_ harness: SystemTwoHarness) {
        guard let backend = backends[harness] else { return }
        backend.stop()
        backend.start()
    }

    private func backendChanged(_ harness: SystemTwoHarness) {
        objectWillChange.send()
        guard let backend = backends[harness] else { return }
        let connection = backend.connection
        defer { lastConnection[harness] = connection }
        // Back online: catch up on what happened while we weren't listening.
        if connection == .connected, lastConnection[harness] != .connected {
            Task {
                await refreshSessions()
                for thread in liveThreads where thread.harness == harness && !thread.sessionID.isEmpty {
                    await thread.load()
                }
            }
        }
    }

    private func deliver(_ event: AgentEvent, to session: String, from harness: SystemTwoHarness) {
        if case .title(let title) = event, let index = sessions.firstIndex(where: { $0.id == session }) {
            sessions[index].title = title
            sessions[index].updated = Date()
        }
        guard let thread = threads[session], thread.harness == harness else { return }
        thread.handle(event)
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

    /// The live thread for a session, or one loaded from its harness.
    func thread(forSession id: String) -> AgentThread {
        if let existing = threads[id] { return existing }
        let summary = sessions.first { $0.id == id }
        let thread = AgentThread(sessionID: id, harness: summary?.harness ?? activeHarness, title: summary?.title ?? "")
        threads[id] = thread
        observe(thread)
        backend(thread.harness).start()
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

    func refreshModelState() {
        activeBackend.refreshModelState()
    }

    // MARK: Sessions

    func refreshSessions() async {
        // Claude Code's history is files on disk, so it's listed even when it isn't selected;
        // Codex is only asked once it's running (listing would start it).
        var all: [AgentSessionSummary] = []
        for (harness, backend) in backends {
            if harness == .codex, backend.connection != .connected { continue }
            all += await backend.listSessions()
        }
        if backends[.claudeCode] == nil { all += await ClaudeBackend.history() }
        sessions = all.sorted { $0.updated > $1.updated }
    }

    func deleteSession(_ id: String) {
        guard let summary = sessions.first(where: { $0.id == id }) else { return }
        Task {
            await backend(summary.harness).delete(id)
            threads[id] = nil
            sessions.removeAll { $0.id == id }
        }
    }
}
