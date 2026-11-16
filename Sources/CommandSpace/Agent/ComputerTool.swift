//
//  ComputerTool.swift
//  Command Space
//
//  The coordinator behind System Two's `computer` tool: checks the settings and the agent's
//  mode, asks the user before control starts (an approval card, once per task or per
//  conversation), gets Command Space out of the way, runs the actions through the driver, and
//  watches for esc so the user can always take the mouse back.
//

import AppKit
import Defaults
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.commandspace", category: "computer-tool")

extension Defaults.Keys {
    static let computerUseEnabled = Key<Bool>("computerUseEnabled", default: true)
    /// Model for conversations started as computer use (command line). Empty = the harness's own model.
    static let computerUseModel = Key<String>("computerUseModel", default: "gpt-6.1-terra")
}

@MainActor
final class ComputerTool: ObservableObject {
    static let shared = ComputerTool()
    static let permissionKind = "computer"

    var driver: ComputerDriver = MacComputer.shared
    /// Command-line runs: no panel, pill or approval cards.
    var headless = false
    /// What macOS access is missing, as a sentence, or nil when control can work. Replaced in tests.
    var missingAccess: () -> String? = { ComputerAccess.missingExplanation }
    /// The session whose agent has the mouse and keyboard right now (drives the live pill).
    @Published private(set) var controlling: String?
    /// The user pressed esc while a session had control. Set by whoever owns sessions; it should abort that session's turn.
    var onStop: (String) -> Void = { _ in }

    private final class StopFlag {
        var stopped = false
    }

    private struct Card {
        let permission: AgentPermission
        let harness: SystemTwoHarness
        var waiters: [CheckedContinuation<PermissionReply, Never>]
    }

    private var conversationGrants = Set<String>()
    private var taskGrants = Set<String>()
    private var cards: [String: Card] = [:]  // by session
    private var flags: [String: StopFlag] = [:]
    private var monitors: [Any] = []
    private init() {}

    // MARK: Tool call

    /// The model called the tool. Applies the rules below, performs the actions, returns the result for the model.
    func call(arguments: Any?, session: String, harness: SystemTwoHarness, mode: AgentMode) async -> ComputerResult {
        func fail(_ text: String) -> ComputerResult { ComputerResult(success: false, text: text, image: nil) }

        let actions: [ComputerAction]
        switch ComputerActions.parse(arguments) {
        case .success(let parsed): actions = parsed
        case .failure(let error): return fail(error.message)
        }
        guard Defaults[.computerUseEnabled] else {
            return fail("Computer use is turned off in Command Space's settings. Tell the user.")
        }
        if mode == .plan, actions.contains(where: { !$0.isReadOnly }) {
            return fail("Plan mode: you may only look (screenshot, wait). Describe what you would do instead.")
        }

        let granted = mode == .fullAccess || conversationGrants.contains(session) || taskGrants.contains(session)
        if headless {
            if !granted { return fail("The user has not allowed computer control for this conversation.") }
            if let missing = missingAccess() { return fail(missing) }
        } else if !granted || missingAccess() != nil {
            let reply = await askApproval(arguments: arguments, session: session, harness: harness)
            switch reply {
            case .reject:
                return fail("The user declined to let you control the computer. Do not try again; ask what they would like instead.")
            case .once: taskGrants.insert(session)
            case .always: conversationGrants.insert(session)
            }
            if let missing = missingAccess() { return fail(missing) }
        }

        let flag = StopFlag()
        flags[session] = flag
        controlling = session
        startEscMonitor()
        if !headless { await leaveCommandSpace() }
        if flag.stopped {
            return fail("The user stopped computer control (esc). Stop now; do not continue the task.")
        }
        log.notice("computer call: \(ComputerActions.summary(of: arguments), privacy: .private)")
        return await driver.perform(actions, shouldStop: { flag.stopped })
    }

    // MARK: Approval

    /// Control is approved for the whole conversation (e.g. it was started as computer use from the command line).
    func grantConversation(_ session: String) {
        conversationGrants.insert(session)
    }

    /// Answers an approval card. Returns false if `permission` isn't one of ours.
    @discardableResult
    func resolve(_ permission: AgentPermission, with reply: PermissionReply) -> Bool {
        guard permission.permission == Self.permissionKind,
              let entry = cards.first(where: { $0.value.permission.id == permission.id }) else { return false }
        finish(card: entry.key, with: reply)
        return true
    }

    /// Approval cards still waiting, for a session (so a reloaded conversation shows them again).
    func pendingPermissions(for session: String) -> [AgentPermission] {
        cards[session].map { [$0.permission] } ?? []
    }

    /// The turn finished or was aborted: forget the per-task approval, cancel a waiting card, release control.
    func turnEnded(_ session: String) {
        taskGrants.remove(session)
        if cards[session] != nil { finish(card: session, with: .reject) }
        flags[session] = nil
        if controlling == session { controlling = nil }
        if controlling == nil { stopEscMonitor() }
    }

    private func askApproval(arguments: Any?, session: String, harness: SystemTwoHarness) async -> PermissionReply {
        await withCheckedContinuation { continuation in
            if cards[session] != nil {
                cards[session]?.waiters.append(continuation)  // same outcome, no second card
                return
            }
            let permission = AgentPermission(
                id: "computer-" + UUID().uuidString,
                sessionID: session,
                permission: Self.permissionKind,
                patterns: [ComputerActions.summary(of: arguments)],
                callID: nil
            )
            cards[session] = Card(permission: permission, harness: harness, waiters: [continuation])
            AgentBackendSink.event(harness, session, .permission(permission))
        }
    }

    private func finish(card session: String, with reply: PermissionReply) {
        guard let card = cards.removeValue(forKey: session) else { return }
        AgentBackendSink.event(card.harness, session, .permissionResolved(card.permission.id))
        for waiter in card.waiters { waiter.resume(returning: reply) }
    }

    // MARK: Getting out of the way

    private static var frontmostIsOther: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    /// Typed into the panel: put the user's app back in front before acting on it.
    private func leaveCommandSpace() async {
        guard let app = NSApp else { return }
        guard app.isActive || CommandPanelController.shared.isVisible else { return }
        let target = ContextCapture.shared.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        CommandPanelController.shared.hide()
        if let target { target.activate() } else { NSApp.hide(nil) }
        let deadline = Date().addingTimeInterval(1.5)
        while !Self.frontmostIsOther, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: Esc to stop

    private var escTap: CFMachPort?
    private var escTapSource: CFRunLoopSource?

    /// An event tap sees every key press, in the app and in command-line runs alike (AppKit's
    /// global monitors stay silent in a process without a UI). It needs only Accessibility,
    /// which control needs anyway; the monitors below are the fallback if the tap is refused.
    private func startEscTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { ComputerTool.shared.resumeEscTap() } }
            } else if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
                      event.getIntegerValueField(.eventSourceUserData) != MacComputer.eventMarker {
                DispatchQueue.main.async { MainActor.assumeIsolated { ComputerTool.shared.userPressedEsc() } }
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Listen-only never delays the user's typing; some systems only grant the default kind.
        let tap = [CGEventTapOptions.listenOnly, .defaultTap].lazy.compactMap {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: $0,
                              eventsOfInterest: mask, callback: callback, userInfo: nil)
        }.first
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        escTap = tap
        escTapSource = source
        return true
    }

    private func resumeEscTap() {
        if let escTap { CGEvent.tapEnable(tap: escTap, enable: true) }
    }

    private func startEscMonitor() {
        guard escTap == nil, monitors.isEmpty else { return }
        if startEscTap() { return }
        let handler: (NSEvent) -> Void = { event in
            guard event.keyCode == 53 else { return }
            let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            guard marker != MacComputer.eventMarker else { return }  // our own key press, not the user's
            Task { @MainActor in ComputerTool.shared.userPressedEsc() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopEscMonitor() {
        if let escTap, let escTapSource {
            CGEvent.tapEnable(tap: escTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escTapSource, .commonModes)
            CFMachPortInvalidate(escTap)
        }
        escTap = nil
        escTapSource = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func userPressedEsc() {
        guard let session = controlling else { return }
        log.notice("user pressed esc; stopping computer control")
        flags[session]?.stopped = true
        onStop(session)
    }
}
