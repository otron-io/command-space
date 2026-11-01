//
//  CommandSpaceApp.swift
//  Command Space
//
//  A menu-bar app (no Dock icon). ⌘Space opens the panel; push-to-talk and whistles reach
//  the agent without it; results and approvals pop up on their own.
//

import AppKit
import Defaults
import Sparkle
import SwiftUI

@main
struct CommandSpaceMain {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-icon"), args.count > flag + 1 {
            let ok = MainActor.assumeIsolated { IconRenderer.render(into: URL(fileURLWithPath: args[flag + 1])) }
            exit(ok ? 0 : 1)
        }
        if let flag = args.firstIndex(of: "--render-moods"), args.count > flag + 1 {
            let ok = MainActor.assumeIsolated { MoodSheet.render(to: URL(fileURLWithPath: args[flag + 1])) }
            exit(ok ? 0 : 1)
        }
        if let flag = args.firstIndex(of: "--harness-check"), args.count > flag + 1 {
            MainActor.assumeIsolated { HarnessCheck.run(args[flag + 1]) }
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private(set) var updater: SPUUpdater?
    private var updaterController: SPUStandardUpdaterController?
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle only makes sense in a signed bundle with a feed (not `swift run`).
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            updaterController = controller
            updater = controller.updater
        }

        installStatusItem()
        HotKeys.register()
        HotKeys.claimSpotlightShortcutIfAgreed()

        _ = AppIndex.shared
        _ = MusicManager.shared
        _ = CalendarManager.shared
        _ = AgentManager.shared
        // Watching ~/Downloads asks for folder access, so it waits until onboarding has explained why.
        if Defaults[.finishedOnboarding] { AmbientMonitor.shared.start() }
        DecisionEngine.shared.warmUpLaya()
        PushToTalk.shared.start()
        WhistleTrigger.shared.start()
        LivePillController.shared.start()
        observeAgent()

        // `open -a "Command Space" --args --query "…"` opens the panel with that text (for scripts).
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--query"), args.count > flag + 1 {
            CommandPanelController.shared.show(mode: .search)
            CommandPanelController.shared.model.query = args[flag + 1]
        } else if args.contains("--conversations") {
            ThreadWindowController.shared.show(nil)
            if let flag = args.firstIndex(of: "--conversations"), args.count > flag + 1, !args[flag + 1].hasPrefix("-") {
                ThreadWindowController.shared.show(AgentManager.shared.thread(forSession: args[flag + 1]))
            }
        } else if args.contains("--settings") {
            SettingsWindowController.shared.show(page: args.contains("--system-two") ? .systemTwo : nil)
        } else if args.contains("--agent") {
            CommandPanelController.shared.show(mode: .agent)
        } else if !Defaults[.finishedOnboarding] {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Launchpad) shows the panel.
        CommandPanelController.shared.show()
        return false
    }

    // MARK: Agent events

    private func observeAgent() {
        // Push-to-talk and whistle requests finished: show the outcome, then tuck it away.
        NotificationCenter.default.addObserver(forName: .agentShowResult, object: nil, queue: .main) { note in
            let dwell = note.userInfo?["dwell"] as? TimeInterval ?? 6
            Task { @MainActor in
                CommandPanelController.shared.peek(mode: .agent, dwell: dwell)
                LivePillController.shared.refresh()
            }
        }
        // Approvals are held by AgentManager (CommandPanelController.setHold), which shows the panel.
        NotificationCenter.default.addObserver(forName: .agentNeedsAttention, object: nil, queue: .main) { _ in
            Task { @MainActor in LivePillController.shared.refresh() }
        }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = SpaceMark.menuBarImage()
            button.toolTip = "Command Space"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Command Space", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Ask Space…", action: #selector(openAgent), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Conversations…", action: #selector(openConversations), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "").target = self
        if updaterController != nil {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Command Space", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() { CommandPanelController.shared.show(mode: .search) }
    @objc private func openAgent() { CommandPanelController.shared.show(mode: .agent) }
    @objc private func openConversations() { ThreadWindowController.shared.show(nil) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openOnboarding() { showOnboarding() }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }

    // MARK: Onboarding

    private func showOnboarding() {
        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Command Space"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Onboarding(
            onFinish: { [weak self] in
                self?.closeOnboarding()
                AmbientMonitor.shared.start()
                CommandPanelController.shared.show()
            },
            onOpenSettings: { [weak self] in
                self?.closeOnboarding()
                AmbientMonitor.shared.start()
                SettingsWindowController.shared.show()
            }
        ))
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}
