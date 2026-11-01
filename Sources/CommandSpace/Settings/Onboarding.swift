//
//  Onboarding.swift
//  Command Space
//
//  First run: welcome (and import from Notch Agent) → ⌘Space → permissions → System Two
//  (the agent) → System One (instant decisions) → done.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    static let finishedOnboarding = Key<Bool>("finishedOnboarding", default: false)
}

struct Onboarding: View {
    enum Step: Int, CaseIterable { case welcome, shortcut, permissions, agent, jev, finish }

    @State private var step: Step
    @State private var importResult: String?
    @ObservedObject private var status = SetupStatus.shared
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    init(initialStep: Step = .welcome, onFinish: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .agent: agent
                case .jev: jev
                case .shortcut: shortcut
                case .finish: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            if step != .welcome {
                HStack(spacing: 6) {
                    ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: s == step ? 18 : 6, height: 6)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: 400, height: 600)
        .animation(.easeInOut(duration: 0.35), value: step)
    }

    private func go(_ next: Step) { withAnimation(.easeInOut(duration: 0.35)) { step = next } }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            SpaceMarkBadge(mood: .idle)
                .frame(width: 140)
                .padding(.bottom, 8)
            Text("Command Space").font(.system(size: 30, weight: .bold))
            Text("Apps, documents, commands and an AI agent,\nall behind ⌘Space.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if NotchAgentImport.isInstalled {
                VStack(spacing: 6) {
                    Button(importResult == nil ? "Import from Notch Agent" : "Imported") {
                        importResult = NotchAgentImport.run()
                    }
                    .disabled(importResult != nil)
                    Text(importResult ?? "Brings over your models, voice and whistle patterns, Spotify, learned actions and Snap 1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .padding(.top, 6)
            }
            Spacer()
            Button("Get started") { go(.shortcut) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
        }
    }

    private var shortcut: some View {
        stepLayout(title: "⌘Space",
                   subtitle: "Command Space replaces Spotlight’s search. To use ⌘Space, it switches Spotlight’s shortcut off (System Settings → Keyboard → Keyboard Shortcuts → Spotlight). You can give it back any time in Settings.",
                   primary: (status.ownsCommandSpace ? "Continue" : "Skip for now", { go(.permissions) })) {
            SetupChecklist(groups: [.shortcut])
            Text("⌥Space goes straight to Space, the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var permissions: some View {
        stepLayout(title: "Permissions",
                   subtitle: "Command Space works best with these. You can change them later in System Settings.",
                   primary: ("Continue", { go(.agent) })) {
            SetupChecklist(groups: [.permissions])
        }
    }

    private var agent: some View {
        stepLayout(title: "System Two: the agent",
                   subtitle: "Questions and tasks go to Space, an AI agent running on opencode, or on your own Codex or Claude Code with your ChatGPT or Claude subscription.",
                   primary: ("Continue", { go(.jev) })) {
            SetupChecklist(groups: [.agent])
            Text("Run the setup command in Terminal once, then choose a model. Every command Space wants to run asks for your approval first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var jev: some View {
        stepLayout(title: "System One: instant",
                   subtitle: "Snap 1 is a small decision model that runs on this Mac. It ranks your search results and runs simple requests (volume, music, reminders, timers, your Shortcuts and actions Space has learned) in a blink, without the agent.",
                   primary: ("Continue", { go(.finish) })) {
            SnapInstallRow()
            Text("Or use Jev, TypeSafe’s hosted version (about a cent a day):")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            JevKeyEntry()
            Text("Optional. Without either, search ranks by name and what you use most, and requests go to the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finish: some View {
        VStack(spacing: 16) {
            Spacer()
            SpaceMarkBadge(mood: .happy).frame(width: 110)
            Text("You're set").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                tip("command", "Press **⌘Space**, type an app, a document or a command")
                tip("arrow.right.to.line", "Press **⇥** to ask Space instead, like “summarize this”")
                tip("keyboard", "Hold **right ⌥** and say “volume 50” or “play some Daft Punk”")
            }
            .padding(.horizontal, 36)
            Spacer()
            HStack {
                Button("Open Settings") {
                    Defaults[.finishedOnboarding] = true
                    onOpenSettings()
                }
                Button("Try it") {
                    Defaults[.finishedOnboarding] = true
                    onFinish()
                }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.bottom, 40)
        }
    }

    // MARK: Helpers

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    private func stepLayout<Content: View>(title: String, subtitle: String, primary: (String, () -> Void),
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 24, weight: .bold)).padding(.top, 50)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
            Spacer()
            HStack {
                Spacer()
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 32)
    }
}

/// Compact Jev key field used in onboarding (Settings has the full section).
struct JevKeyEntry: View {
    @State private var key = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(DecisionEngine.shared.hasJevKey ? "Key saved · paste to replace" : "Jev API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button(testing ? "Testing…" : "Save & test") {
                    testing = true
                    if !key.isEmpty { JevKeychain.save(key) }
                    key = ""
                    Task {
                        result = await DecisionEngine.shared.testJev()
                        testing = false
                    }
                }
                .disabled(testing || (key.isEmpty && !DecisionEngine.shared.hasJevKey))
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(result.hasPrefix("OK") ? .green : .orange)
            }
        }
    }
}

/// Download or show Snap 1 (onboarding; Settings → System One has the full section).
struct SnapInstallRow: View {
    @ObservedObject private var store = LayaModelStore.shared

    var body: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Snap 1").font(.system(size: 12, weight: .medium))
            Spacer()
            switch store.status {
            case .notInstalled:
                Button("Download") { store.install() }
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 120)
                Button("Cancel") { store.cancel() }
            case .installed(let version):
                Label("Installed \(version)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
                Button("Retry") { store.install() }
            }
        }
        .controlSize(.small)
        .onChange(of: store.status) { _, status in
            if case .installed = status {
                Defaults[.decisionBackend] = .local
                DecisionEngine.shared.warmUpLaya()
            }
        }
    }
}
