//
//  AgentModeViews.swift
//  Command Space
//
//  The mode chip (panel and conversation window), the plan approval card and the
//  "Run this plan" bar shown after a plan-mode reply.
//

import SwiftUI

/// Shows a conversation's mode; click for the list, ⇧⇥ in the panel cycles.
struct AgentModeChip: View {
    @ObservedObject var thread: AgentThread
    var compact = false

    var body: some View {
        Menu {
            ForEach(thread.harness.modes) { mode in
                Button {
                    thread.setMode(mode)
                } label: {
                    Label(mode.name + (mode == thread.harness.defaultMode ? " (default)" : ""),
                          systemImage: thread.mode == mode ? "checkmark" : mode.icon)
                }
                .help(mode.summary(on: thread.harness))
            }
            Divider()
            Text(thread.mode.summary(on: thread.harness))
            Button("Default modes…") { SetupStatus.openSettings(.systemTwo) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: thread.mode.icon)
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text(thread.mode.name)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(thread.mode.name) · \(thread.mode.summary(on: thread.harness))\n⇧⇥ to switch")
        .animation(.smooth(duration: 0.2), value: thread.mode)
    }

    private var foreground: Color {
        switch thread.mode {
        case .plan: return Color(red: 0.6, green: 0.85, blue: 1)
        case .fullAccess: return Color(red: 1, green: 0.62, blue: 0.5)
        case .auto: return Color(red: 0.95, green: 0.8, blue: 0.45)
        default: return .white.opacity(0.8)
        }
    }

    private var background: Color {
        switch thread.mode {
        case .plan: return Color.blue.opacity(0.22)
        case .fullAccess: return Color.red.opacity(0.22)
        case .auto: return Color.yellow.opacity(0.16)
        default: return Color.white.opacity(0.08)
        }
    }
}

/// The agent wants to leave plan mode with this plan.
struct PlanApprovalCard: View {
    let plan: String
    let onReply: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ready to go ahead with this plan?", systemImage: "list.bullet.clipboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1))
            ScrollView(.vertical, showsIndicators: false) {
                Text(LocalizedStringKey(plan))
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                button("Keep planning", "reject", tint: .white.opacity(0.1))
                Spacer()
                button("Approve, accept edits", "always", tint: .white.opacity(0.1))
                button("Approve", "once", tint: .blue.opacity(0.5))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ title: String, _ reply: String, tint: Color) -> some View {
        Button { onReply(reply) } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }
}

/// Under a plan-mode reply: run it in the harness's working mode.
struct PlanReadyCard: View {
    @ObservedObject var thread: AgentThread

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1))
            Text("Plan ready").foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 4)
            Button {
                thread.runPlan()
            } label: {
                Text("Run in \(thread.harness.executionMode.name)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.45)))
            }
            .buttonStyle(.plain)
            Button { thread.dismissPlan() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.08)))
    }
}
