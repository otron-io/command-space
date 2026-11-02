//
//  CommandPanelController.swift
//  Command Space
//
//  The floating panel. It never activates Command Space, so the app you were in stays
//  frontmost: "this" (your selection, the page you're on) still refers to it, and closing
//  the panel drops you right back where you were.
//

import AppKit
import Defaults
import SwiftUI

final class CommandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CommandPanelController.size.width, height: CommandPanelController.size.height),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the bubbles draw their own
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandPanelController: NSObject, NSWindowDelegate {
    static let shared = CommandPanelController()
    static let size = NSSize(width: 760, height: 620)

    let model = CommandSpaceModel()
    private let panel = CommandPanel()
    private var keyMonitor: Any?
    private var holds: Set<String> = []
    private var peekTask: Task<Void, Never>?
    /// Shown without keyboard focus (a result or approval popped up on its own).
    private(set) var isPeeking = false

    var isVisible: Bool { panel.isVisible }

    private override init() {
        super.init()
        let host = NSHostingView(rootView: CommandSpaceView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        model.onHide = { [weak self] in self?.hide() }
    }

    // MARK: Showing

    func toggle(mode: CommandSpaceModel.Mode = .search) {
        // ⌥Space while the panel already shows a conversation flips back to it rather than closing.
        if panel.isVisible && panel.isKeyWindow && model.mode == mode {
            hide()
        } else {
            show(mode: mode)
        }
    }

    /// - Parameter thread: show this conversation; otherwise a fresh open starts a new thread
    ///   (the previous one stays in history, and keeps running if it's working).
    func show(mode: CommandSpaceModel.Mode = .search, thread: AgentThread? = nil) {
        peekTask?.cancel()
        isPeeking = false
        let wasVisible = panel.isVisible
        if let thread {
            AgentManager.shared.makeCurrent(thread)
        } else if !wasVisible {
            AgentManager.shared.newThread()
        }
        if !wasVisible {
            position()
            ContextCapture.shared.begin(allowCopyFallback: false)
            AppIndex.shared.refresh()
        }
        model.prepare(mode: mode, fresh: !wasVisible)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        model.present()
        LivePillController.shared.refresh()
    }

    /// Shows the panel without taking focus, then tucks it away after `dwell` seconds
    /// (kept while the pointer is over it, or while something holds it open).
    func peek(mode: CommandSpaceModel.Mode, dwell: TimeInterval?) {
        if panel.isVisible && panel.isKeyWindow {
            model.mode = mode
            return
        }
        if !panel.isVisible {
            position()
            model.prepare(mode: mode, fresh: true)
            panel.orderFrontRegardless()
            model.present()
        } else {
            model.mode = mode
        }
        isPeeking = true
        peekTask?.cancel()
        guard let dwell else { return }
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            while let self, self.isPointerInside || !self.holds.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self, self.isPeeking else { return }
            self.hide()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        peekTask?.cancel()
        isPeeking = false
        removeKeyMonitor()
        model.dismiss { [weak self] in
            guard let self, !self.model.isPresented else { return }
            self.panel.orderOut(nil)
            self.model.reset()
            LivePillController.shared.refresh()
        }
    }

    /// Something that needs the panel to stay up (e.g. an approval waiting for an answer).
    func setHold(_ reason: String, _ on: Bool) {
        if on { holds.insert(reason) } else { holds.remove(reason) }
        if on && !panel.isVisible { peek(mode: .agent, dwell: nil) }
        if !on && holds.isEmpty && isPeeking { peek(mode: model.mode, dwell: 1.5) }
    }

    private var isPointerInside: Bool {
        model.interactiveFrame(in: panel).contains(NSEvent.mouseLocation)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // Upper middle: the bubble's top sits about a fifth of the way down the screen.
        let top = visible.maxY - visible.height * 0.18
        let size = Self.size
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: false)
    }

    #if DEBUG
    /// App-owned view capture for UI smoke tests; never screenshots the user's desktop.
    func saveSnapshot(to url: URL) -> Bool {
        guard let view = panel.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
    #endif

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicked elsewhere: go away, unless an approval is waiting.
        guard holds.isEmpty else {
            isPeeking = true
            return
        }
        hide()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // A peeking panel that got clicked becomes a normal one.
        if isPeeking {
            isPeeking = false
            peekTask?.cancel()
            installKeyMonitor()
            model.focusField()
        }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            // Let input methods finish composing (Japanese, Chinese, accents…).
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
