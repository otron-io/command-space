//
//  CommandSpaceModel.swift
//  Command Space
//
//  State and keyboard behaviour of the panel.
//
//    ⏎        open the selected result (or send, when talking to Space)
//    ⌘⏎       reveal in Finder
//    ⌥⏎       search Google for what you typed (default browser)
//    ⇥        ask Space (the agent) what you typed
//    ↑ ↓      move the selection;  ⌘1…9 open that row
//    esc      clear, go back, close
//    ⌘N       new conversation;  ⌘O  open it in a window;  ⌘Y  all conversations;  ⌘,  settings
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class CommandSpaceModel: ObservableObject {
    enum Mode: Equatable { case search, agent }

    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published var mode: Mode = .search
    @Published var selection = 0
    /// Drives the bubble → bar → results animation.
    @Published private(set) var stage: Stage = .hidden
    @Published var focusToken = 0

    enum Stage: Int, Comparable {
        case hidden, bubble, bar
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    let search = SearchEngine()
    var onHide: (() -> Void)?
    var isPresented: Bool { stage != .hidden }

    /// Frames of the visible bubbles in window coordinates, reported by the view (for hover checks).
    var barFrame: CGRect = .zero
    var cardFrame: CGRect = .zero

    private var cancellables: Set<AnyCancellable> = []
    private var agent: AgentManager { .shared }

    init() {
        search.$results
            .sink { [weak self] _ in self?.selection = 0 }
            .store(in: &cancellables)
    }

    var results: [SearchResult] { search.results }

    var selectedResult: SearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// Whether the card under the bar has anything to show.
    var showsCard: Bool {
        switch mode {
        case .agent: return true
        case .search: return !query.trimmingCharacters(in: .whitespaces).isEmpty || hasLiveAgentState
        }
    }

    var hasLiveAgentState: Bool {
        agent.anyBusy || agent.anyPermissions || AmbientMonitor.shared.nudge != nil
    }

    // MARK: Lifecycle

    func prepare(mode: Mode, fresh: Bool) {
        self.mode = mode
        if fresh {
            query = ""
            selection = 0
        }
    }

    func present() {
        lastPointer = NSEvent.mouseLocation
        if stage == .hidden {
            stage = .bubble
            // Let the bubble land, then stretch it into the bar.
            Task {
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { stage = .bar }
                focusField()
            }
        } else {
            focusField()
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        withAnimation(.smooth(duration: 0.16)) { stage = .bubble }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeIn(duration: 0.1)) { stage = .hidden }
            try? await Task.sleep(for: .milliseconds(100))
            completion()
        }
    }

    func reset() {
        query = ""
        mode = .search
        selection = 0
    }

    func focusField() { focusToken += 1 }

    /// Hover selects a row only when the pointer actually moves (rows sliding in under a
    /// resting pointer shouldn't steal the selection from the keyboard).
    private var lastPointer = NSEvent.mouseLocation

    func hovered(_ index: Int) {
        let pointer = NSEvent.mouseLocation
        guard pointer != lastPointer else { return }
        lastPointer = pointer
        selection = index
    }

    func interactiveFrame(in window: NSWindow) -> CGRect {
        let union = cardFrame == .zero ? barFrame : barFrame.union(cardFrame)
        // SwiftUI frames are top-left based; flip into screen coordinates.
        let height = window.frame.height
        let flipped = CGRect(x: union.minX, y: height - union.maxY, width: union.width, height: union.height)
        return window.convertToScreen(flipped)
    }

    private func queryChanged() {
        if !query.isEmpty { SpaceMarkEvents.typed(length: query.count) }
        if mode == .search { search.update(query: query) }
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: move(1); return true                       // ↓
        case 126: move(-1); return true                      // ↑
        case 48:                                             // ⇥
            if event.modifierFlags.contains(.shift) { mode = .search; search.update(query: query); return true }
            askSpace()
            return true
        case 53: escape(); return true                       // esc
        case 36, 76:                                         // ⏎
            if command { reveal() } else if event.modifierFlags.contains(.option) { searchWeb() } else { activate() }
            return true
        default:
            break
        }
        guard command, let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "n":
            agent.newThread()
            mode = .agent
            return true
        case "o":
            openInWindow()
            return true
        case "y":
            showConversations()
            return true
        case ",":
            onHide?()
            SettingsWindowController.shared.show()
            return true
        case "1"..."9":
            if mode == .search, let n = Int(chars), results.indices.contains(n - 1) {
                selection = n - 1
                activate()
                return true
            }
            return false
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard mode == .search, !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func escape() {
        if !query.isEmpty {
            query = ""
        } else if mode == .agent {
            mode = .search
        } else {
            onHide?()
        }
    }

    // MARK: Actions

    func askSpace() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.smooth(duration: 0.25)) { mode = .agent }
        guard !text.isEmpty else { return }
        query = ""
        agent.send(text)
    }

    /// Moves the panel's conversation into the big window.
    func openInWindow() {
        let thread = agent.current
        onHide?()
        ThreadWindowController.shared.show(thread.isEmpty ? nil : thread)
    }

    func showConversations() {
        onHide?()
        ThreadWindowController.shared.show(nil)
    }

    func prefill(_ text: String) {
        query = text
        focusField()
    }

    func activate() {
        if mode == .agent {
            askSpace()
            return
        }
        guard let result = selectedResult else {
            if !query.isEmpty { askSpace() }
            return
        }
        perform(result)
    }

    func perform(_ result: SearchResult) {
        let typed = query
        UsageStore.recordPick(result.kind == .ask || result.kind == .web ? result.kind.rawValue : result.id, query: typed)
        switch result.action {
        case .open(let url):
            open(url)
            onHide?()
        case .ask:
            askSpace()
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            agent.flashResult(icon: "doc.on.doc", label: "Copied \(text)")
            onHide?()
        case .system(let id):
            onHide?()
            QuickOpen.systemCommands.first { $0.id == id }?.run()
        case .resolved(let command):
            onHide?()
            Task {
                if let outcome = await CommandPreview.run(command) {
                    agent.flashResult(icon: outcome.icon, label: outcome.label)
                }
            }
        case .conversation(let id):
            onHide?()
            ThreadWindowController.shared.show(agent.thread(forSession: id))
        case .shortcut(let name):
            onHide?()
            Task {
                let ok = await SystemBridge.shared.runShortcut(name)
                agent.flashResult(icon: ok ? "square.stack.3d.up.fill" : "exclamationmark.triangle.fill",
                                  label: ok ? "Ran \(name)" : "Couldn't run \(name)")
            }
        case .command(let id, let standalone):
            if standalone {
                onHide?()
                Task {
                    if let outcome = await QuickActions.shared.run(commandID: id) {
                        agent.flashResult(icon: outcome.icon, label: outcome.label)
                    }
                }
            } else if Self.carriesDetails(typed, for: id) {
                // "volume 40", "remind me to call mom at 6": System One reads the details.
                onHide?()
                query = ""
                agent.send(typed, showResult: true)
            } else {
                prefill(Self.template(for: id))
            }
        }
    }

    /// Google search in the default browser.
    func searchWeb() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = QuickOpen.webSearchURL(text) else { return }
        UsageStore.recordPick("web", query: text)
        NSWorkspace.shared.open(url)
        onHide?()
    }

    func reveal() {
        guard mode == .search, let url = selectedResult?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onHide?()
    }

    private func open(_ url: URL) {
        if url.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Commands that need details (a level, a song, a time) start from a phrase you finish.
    private static func template(for id: String) -> String {
        switch id {
        case "set_volume": return "Set volume to "
        case "set_brightness": return "Set brightness to "
        case "play_music": return "Play "
        case "add_reminder": return "Remind me to "
        case "add_event": return "Add event "
        case "set_timer": return "Timer for "
        case "run_shortcut": return "Run shortcut "
        default: return ""
        }
    }

    private static func carriesDetails(_ typed: String, for id: String) -> Bool {
        let words = typed.split(separator: " ")
        let template = Self.template(for: id).trimmingCharacters(in: .whitespaces).lowercased()
        if !template.isEmpty, template.hasPrefix(typed.lowercased().trimmingCharacters(in: .whitespaces)) { return false }
        return typed.contains(where: \.isNumber) || words.count >= 2
    }
}
