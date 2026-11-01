//
//  SettingsWindow.swift
//  Command Space
//

import AppKit
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Command Space Settings"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRoot())
        window.center()
        window.setFrameAutosaveName("CommandSpaceSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A page asked for before the window's view was listening (first open).
    static var pendingPage: String?

    func show(page: AgentSettingsPage? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let page {
            Self.pendingPage = page.rawValue
            NotificationCenter.default.post(name: .openAgentSettingsPage, object: nil, userInfo: ["page": page.rawValue])
        }
    }
}

private struct SettingsRoot: View {
    @State private var selection: String = AgentSettingsPage.agent.rawValue

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AgentSettingsPage.allCases, id: \.rawValue) { page in
                    Label(page.rawValue, systemImage: page.icon).tag(page.rawValue)
                }
                Label("About", systemImage: "info.circle").tag("About")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let page = AgentSettingsPage(rawValue: selection) {
                AgentSettings(page: page).id(page)
            } else {
                AboutSettings()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        // The pages are written for grouped forms (as in Notch Agent); the default column style breaks them.
        .formStyle(.grouped)
        .frame(minWidth: 700, minHeight: 520)
        .onAppear {
            if let page = SettingsWindowController.pendingPage { selection = page }
            SettingsWindowController.pendingPage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAgentSettingsPage)) { note in
            if let page = note.userInfo?["page"] as? String { selection = page }
        }
    }
}

/// Shortcuts, Spotlight, search options and startup (shown on the General page).
struct GeneralSettingsSections: View {
    @State private var spotlightEnabled = SpotlightShortcut.isEnabled
    @State private var importResult: String?

    var body: some View {
        Section {
            KeyboardShortcuts.Recorder("Open Command Space:", name: .toggleCommandSpace)
            KeyboardShortcuts.Recorder("Ask Space directly:", name: .askSpace)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotlight’s ⌘Space")
                    Text(spotlightEnabled ? "On. Spotlight still opens with ⌘Space, so Command Space can’t use it."
                                          : "Off. ⌘Space opens Command Space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if spotlightEnabled {
                    Button("Take over ⌘Space") {
                        SetupStatus.shared.takeOverCommandSpace()
                        spotlightEnabled = SpotlightShortcut.isEnabled
                    }
                } else {
                    Button("Give back to Spotlight") {
                        HotKeys.releaseSpotlightShortcut()
                        spotlightEnabled = SpotlightShortcut.isEnabled
                    }
                }
            }
        } header: {
            Text("Shortcuts")
        }

        Section {
            Defaults.Toggle("Search documents and folders", key: .searchFiles)
            Defaults.Toggle("Rank results with Snap 1", key: .searchSnapRanking)
            Defaults.Toggle("Offer a web search", key: .searchWebFallback)
        } header: {
            Text("Search")
        } footer: {
            Text("Snap 1 runs on this Mac and reads only what you type and the names of matching results. Install it under System One. Without it, results are ranked by name and by what you open most.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            LaunchAtLogin.Toggle("Open at login")
            if NotchAgentImport.isInstalled {
                HStack {
                    Text("Notch Agent")
                    Spacer()
                    if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
                    Button("Import its settings") { importResult = NotchAgentImport.run() }
                }
            }
        } header: {
            Text("Startup")
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        VStack(spacing: 14) {
            SpaceMarkBadge(mood: .idle).frame(width: 110)
            Text("Command Space").font(.system(size: 26, weight: .bold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Apps, documents, commands and an agent, one keystroke away.")
                .foregroundStyle(.secondary)
            if let updater = AppDelegate.shared?.updater {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
