//
//  HarnessSettings.swift
//  Command Space
//
//  Settings → System Two: which agent harness runs new conversations, and the model for
//  Codex / Claude Code. Existing conversations stay on the harness they started on.
//

import Defaults
import SwiftUI

struct HarnessPickerSection: View {
    @Default(.systemTwoHarness) private var harness
    @ObservedObject private var detector = HarnessDetector.shared
    @ObservedObject private var manager = AgentManager.shared

    var body: some View {
        Section {
            ForEach(SystemTwoHarness.allCases) { option in
                HarnessRow(harness: option, status: detector.status(option), selected: harness == option) {
                    harness = option
                }
            }
        } header: {
            HStack {
                Text("Harness")
                Spacer()
                if detector.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Check again") { Task { await detector.refresh() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        } footer: {
            Text("The harness runs Space's agent. Codex and Claude Code use the subscription you signed them into (ChatGPT or Claude), never an API key. New conversations use the harness chosen here; existing ones stay on the harness they started on.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .task { await detector.refresh() }
    }
}

private struct HarnessRow: View {
    let harness: SystemTwoHarness
    let status: HarnessStatus
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(harness.name)
                .accessibilityValue(selected ? "selected" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Spacer()
            if harness != .opencode, status.installed, !status.ready, let login = harness.loginCommand {
                Button("Sign in…") { HarnessLogin.open(login) }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .font(.system(size: 14))
            Image(systemName: harness.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        switch harness {
        case .opencode:
            return status.installed ? "Local server · models and keys managed below" : "Not installed · run the setup command in General"
        case .codex, .claudeCode:
            guard status.installed else {
                return status.loggedIn == nil && status.path == nil && status.version == nil
                    ? "Not installed · \(harness.installHint)" : "Checking…"
            }
            let version = status.version.map { "\($0) · " } ?? ""
            if status.usesAPIKey { return "\(version)signed in with an API key; sign in with your \(harness.accountName) plan instead" }
            switch status.loggedIn {
            case true?: return "\(version)signed in with \(status.account ?? harness.accountName)"
            case false?: return "\(version)not signed in"
            case nil: return "\(version)checking sign-in…"
            }
        }
    }

    private var detailColor: Color {
        if harness == .opencode || status.ready { return .secondary }
        return status.installed ? .orange : .secondary
    }
}

/// Model choice for Codex and Claude Code.
struct HarnessModelSection: View {
    let harness: SystemTwoHarness
    @ObservedObject private var manager = AgentManager.shared
    @Default(.codexModel) private var codexModel
    @Default(.claudeModel) private var claudeModel

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                status
            }
            Picker("Model", selection: model) {
                Text("Default").tag("")
                ForEach(options, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
                if !model.wrappedValue.isEmpty, !options.contains(where: { $0.id == model.wrappedValue }) {
                    Text(model.wrappedValue).tag(model.wrappedValue)
                }
            }
            if harness == .codex, options.isEmpty {
                Text("Models load once Codex is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(harness.name)
        } footer: {
            Text(footer)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .onChange(of: codexModel) { manager.refreshModelState() }
        .onChange(of: claudeModel) { manager.refreshModelState() }
    }

    private var model: Binding<String> {
        harness == .codex ? $codexModel : $claudeModel
    }

    private var options: [(id: String, name: String)] {
        switch harness {
        case .codex: return manager.codexModels
        case .claudeCode: return [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        case .opencode: return []
        }
    }

    private var footer: String {
        switch harness {
        case .codex:
            return "Runs `codex app-server` with your ChatGPT sign-in. Commands Codex knows are read-only run straight away; anything else asks for your approval. Conversations live in Codex's own history (~/.codex)."
        case .claudeCode:
            return "Runs `claude` with your Claude sign-in, one process per conversation. Anything with side effects asks for your approval. Conversations live in Claude Code's history for ~/CommandSpace/workspace, so `claude --resume` in that folder opens them too."
        case .opencode:
            return ""
        }
    }

    @ViewBuilder
    private var status: some View {
        let connection = manager.backend(harness).connection
        HStack(spacing: 6) {
            switch connection {
            case .connected:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Ready").foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Starting…").foregroundStyle(.secondary)
            case .offline(let reason):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(reason).foregroundStyle(.secondary).lineLimit(2)
                Button("Try again") { manager.restart(harness) }
            }
        }
    }
}

/// The mode new conversations on a harness start in (each conversation can switch with ⇧⇥).
struct HarnessModeSection: View {
    let harness: SystemTwoHarness
    @State private var selection: AgentMode = .ask

    var body: some View {
        Section {
            ForEach(harness.modes) { mode in
                Button {
                    selection = mode
                    Defaults[harness.defaultModeKey] = mode
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selection == mode ? Color.accentColor : .secondary)
                            .font(.system(size: 14))
                        Image(systemName: mode.icon)
                            .frame(width: 18)
                            .foregroundStyle(mode == .fullAccess ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.name)
                            Text(mode.summary(on: harness))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.name)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        } header: {
            Text("Default mode")
        } footer: {
            Text("New \(harness.name) conversations start in this mode. Switch a conversation's mode from the chip next to the conversation, or with ⇧⇥ in Command Space.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .onAppear { selection = harness.defaultMode }
        .onChange(of: harness) { selection = harness.defaultMode }
    }
}
