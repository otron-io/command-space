//
//  SetupChecklist.swift
//  Command Space
//
//  What Command Space needs to be fully working, with a fix button for each item.
//  Shown in onboarding and in Settings → General.
//

import AppKit
import AVFoundation
import Defaults
import EventKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.otron.commandspace", category: "setup")

extension Notification.Name {
    /// userInfo["page"] = AgentSettingsPage raw value
    static let openAgentSettingsPage = Notification.Name("openAgentSettingsPage")
}

@MainActor
final class SetupStatus: ObservableObject {
    static let shared = SetupStatus()

    static let setupCommand = "curl -fsSL https://raw.githubusercontent.com/otron-io/command-space/main/agent/setup.sh | zsh"

    @Published private(set) var agentRunning: Bool?
    @Published private(set) var modelName: String?
    @Published private(set) var accessibility: Bool?
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var calendars = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var jevKey = false
    @Published private(set) var spotify = false
    @Published private(set) var notchAgentRunning = false
    @Published private(set) var ownsCommandSpace = false

    private init() {}

    func refresh() async {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        calendars = EKEventStore.authorizationStatus(for: .event)
        reminders = EKEventStore.authorizationStatus(for: .reminder)
        jevKey = DecisionEngine.shared.hasJevKey
        spotify = SpotifyClient.shared.isConnected
        notchAgentRunning = NotchAgentImport.isRunning
        ownsCommandSpace = !SpotlightShortcut.isEnabled
        accessibility = await SystemBridge.shared.isAccessibilityAuthorized()

        let harness = Defaults[.systemTwoHarness]
        if harness != .opencode {
            await HarnessDetector.shared.refresh()
            let status = HarnessDetector.shared.status(harness)
            agentRunning = status.ready
            modelName = status.ready ? (status.account ?? harness.accountName) : nil
            return
        }
        let client = OpencodeConfigClient.shared
        await client.refreshHealth()
        if case .healthy = client.health {
            agentRunning = true
            await client.reload(includeCatalog: false)
            let (provider, _) = OpencodeConfigClient.split(client.activeModel)
            modelName = client.connected.contains { $0.id == provider } ? client.activeModel : nil
        } else {
            agentRunning = false
            modelName = nil
        }
    }

    // MARK: Fixes

    func requestAccessibility() {
        SystemBridge.shared.requestAccessibilityAuthorization()
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            Self.openPrivacyPane("Privacy_Microphone")
        }
        await refresh()
    }

    func requestCalendarAndReminders() async {
        let store = EKEventStore()
        if calendars == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        if reminders == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        if calendars != .notDetermined && calendars != .fullAccess { Self.openPrivacyPane("Privacy_Calendars") }
        await refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSettings(_ page: AgentSettingsPage) {
        SettingsWindowController.shared.show(page: page)
    }

    func takeOverCommandSpace() {
        Defaults[.tookOverSpotlight] = true
        SpotlightShortcut.set(enabled: false)
        HotKeys.reregister()
        ownsCommandSpace = !SpotlightShortcut.isEnabled
    }
}

// MARK: - View

struct SetupChecklist: View {
    enum Group { case shortcut, permissions, agent, extras }

    var groups: [Group] = [.shortcut, .permissions, .agent, .extras]
    @ObservedObject private var status = SetupStatus.shared
    @ObservedObject private var detector = HarnessDetector.shared
    @Default(.systemTwoHarness) private var harness
    @State private var copied = false

    private func harnessDetail(_ detected: HarnessStatus) -> String {
        guard detected.installed else { return "Not installed. \(harness.installHint)" }
        if detected.usesAPIKey { return "Signed in with an API key. Sign in with your \(harness.accountName) plan instead." }
        if detected.loggedIn == false { return "Installed, not signed in" }
        let version = detected.version.map { " \($0)" } ?? ""
        return "\(harness.name)\(version) · \(detected.account ?? harness.accountName) subscription"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.contains(.shortcut) {
                row(icon: "command", title: "⌘Space",
                    detail: status.ownsCommandSpace ? "Opens Command Space instead of Spotlight" : "Spotlight still has it",
                    state: status.ownsCommandSpace ? .ok : .missing) {
                    Button("Use for Command Space") { status.takeOverCommandSpace() }
                }
            }
            if groups.contains(.agent), harness != .opencode {
                let detected = HarnessDetector.shared.status(harness)
                row(icon: harness.icon, title: harness.name,
                    detail: harnessDetail(detected),
                    state: status.agentRunning.map { $0 ? .ok : .missing } ?? .checking) {
                    if detected.installed, let login = harness.loginCommand {
                        Button("Sign in…") { HarnessLogin.open(login) }
                    } else {
                        Button("Choose…") { SetupStatus.openSettings(.systemTwo) }
                    }
                }
            } else if groups.contains(.agent) {
                row(icon: "server.rack", title: "Background agent",
                    detail: status.agentRunning == false ? "Not running. Run the setup command in Terminal." : "opencode is running",
                    state: status.agentRunning.map { $0 ? .ok : .missing } ?? .checking) {
                    Button(copied ? "Copied" : "Copy setup command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SetupStatus.setupCommand, forType: .string)
                        copied = true
                    }
                }
                row(icon: "cpu", title: "Model",
                    detail: status.modelName ?? "Log in with ChatGPT or add an API key",
                    state: status.agentRunning != true ? .blocked : (status.modelName != nil ? .ok : .missing)) {
                    Button("Choose…") { SetupStatus.openSettings(.systemTwo) }
                }
            }
            if groups.contains(.permissions) {
                row(icon: "keyboard", title: "Accessibility",
                    detail: "For push-to-talk, media keys, menu commands and “this”",
                    state: status.accessibility.map { $0 ? .ok : .missing } ?? .checking) {
                    Button("Allow") { status.requestAccessibility() }
                }
                row(icon: "mic.fill", title: "Microphone",
                    detail: "Voice input, transcribed on this Mac",
                    state: status.microphone == .authorized ? .ok : .missing) {
                    Button("Allow") { Task { await status.requestMicrophone() } }
                }
                row(icon: "calendar", title: "Calendar & Reminders",
                    detail: "Shows events and adds reminders/events instantly",
                    state: status.calendars == .fullAccess && status.reminders == .fullAccess ? .ok : .missing) {
                    Button("Allow") { Task { await status.requestCalendarAndReminders() } }
                }
            }
            if groups.contains(.extras) {
                row(icon: "bolt.fill", title: "Instant decisions",
                    detail: "Optional · Snap 1 on this Mac, or a Jev key, makes simple requests run instantly",
                    state: status.jevKey || LayaModelStore.shared.modelDirectory != nil ? .ok : .optional) {
                    Button("Set up…") { SetupStatus.openSettings(.systemOne) }
                }
                row(icon: "music.note", title: "Spotify",
                    detail: "Optional · Premium, for instant songs and playlists",
                    state: status.spotify ? .ok : .optional) {
                    Button("Connect…") { SetupStatus.openSettings(.spotify) }
                }
                if status.notchAgentRunning {
                    row(icon: "arrow.triangle.2.circlepath", title: "Notch Agent is running",
                        detail: "Both listen for push-to-talk and whistles",
                        state: .missing) {
                        Button("Quit Notch Agent") { NotchAgentImport.quitNotchAgent() }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await status.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private enum RowState { case ok, missing, optional, blocked, checking }

    private func row<Fix: View>(icon: String, title: String, detail: String, state: RowState,
                                @ViewBuilder fix: () -> Fix) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .checking:
                ProgressView().controlSize(.small)
            case .blocked:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .missing, .optional:
                fix().controlSize(.small)
            }
        }
    }
}
