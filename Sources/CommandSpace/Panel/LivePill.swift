//
//  LivePill.swift
//  Command Space
//
//  What the closed notch used to show, as a small black pill at the top of the screen:
//  listening, instant results, timers, work in progress, approvals and nudges.
//  Click it to open Command Space on the conversation.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LivePillController {
    static let shared = LivePillController()

    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: LivePillView())
        panel.ignoresMouseEvents = false
    }

    func start() {
        let agent = AgentManager.shared
        let voice = VoiceInput.shared
        let timers = AgentTimers.shared
        let monitor = AmbientMonitor.shared
        Publishers.MergeMany(
            agent.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            voice.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            timers.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            monitor.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
        .sink { [weak self] in self?.update() }
        .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in LivePillController.shared.position() }
        }
        position()
    }

    private var hasContent: Bool {
        let agent = AgentManager.shared
        return VoiceInput.shared.isActive || agent.isRoutingVoice || agent.quickResult != nil
            || agent.anyBusy || agent.anyPermissions || AgentTimers.shared.next != nil
            || AmbientMonitor.shared.nudge != nil
    }

    private func update() {
        // Command Space itself shows all of this while it's open.
        let show = hasContent && !CommandPanelController.shared.isVisible
        if show && !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        } else if !show && panel.isVisible {
            // Let the pill animate out first.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !(self.hasContent && !CommandPanelController.shared.isVisible) { self.panel.orderOut(nil) }
            }
        }
    }

    func refresh() { update() }

    private func position() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let top = screen.visibleFrame.maxY - 6
        panel.setFrame(NSRect(x: frame.midX - 230, y: top - 190, width: 460, height: 190), display: false)
    }
}

struct LivePillView: View {
    @ObservedObject private var manager = AgentManager.shared
    /// The thread doing something (it may not be the panel's).
    private var agent: AgentThread { manager.mostRelevantThread ?? manager.current }
    @ObservedObject private var voice = VoiceInput.shared
    @ObservedObject private var timers = AgentTimers.shared
    @ObservedObject private var monitor = AmbientMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            if let content {
                pill(content)
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            }
            if let nudge = monitor.nudge, !voice.isActive {
                NudgeCard(nudge: nudge, onButton: { monitor.perform($0) }, onDismiss: { monitor.dismiss() })
                    .frame(width: 420, height: 96)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Space.black))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Space.hairline, lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 460, height: 190, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: content)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: monitor.nudge?.id)
        .environment(\.colorScheme, .dark)
    }

    private struct Content: Equatable {
        var mood: SpaceMood
        var icon: String?
        var tint: Color = .gray
        var text: String
        var trailing: String?
        var glow: Color = .clear
    }

    private var content: Content? {
        if voice.isActive {
            return Content(mood: .listening, text: voice.transcript.isEmpty ? (voice.state == .finishing ? "Transcribing…" : "Listening…") : voice.transcript,
                           glow: Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.4 + 0.5 * Double(voice.level)))
        }
        if manager.isRoutingVoice { return Content(mood: .thinking, text: "On it…") }
        if let result = manager.quickResult {
            return Content(mood: .idle, icon: result.icon, tint: .yellow, text: result.label, glow: .yellow.opacity(0.35))
        }
        if !agent.permissions.isEmpty {
            return Content(mood: .attention, icon: "hand.raised.fill", tint: .yellow, text: "Space needs your approval", glow: .yellow.opacity(0.35))
        }
        if agent.isBusy {
            var text = "Working"
            if let tool = agent.runningTool, case .tool(let name, _) = tool.kind { text += " · \(name)" }
            return Content(mood: .working, text: text,
                           trailing: agent.taskStartedAt.map { AgentActivityView.clock(Date().timeIntervalSince($0)) })
        }
        if let timer = timers.next {
            return Content(mood: .idle, icon: "timer", tint: .orange, text: timer.label.map { "\($0) timer" } ?? "Timer",
                           trailing: AgentTimers.format(timer.end.timeIntervalSinceNow))
        }
        return nil
    }

    private func pill(_ content: Content) -> some View {
        Button {
            CommandPanelController.shared.show(mode: .agent, thread: manager.mostRelevantThread ?? (manager.current.isEmpty ? nil : manager.current))
            LivePillController.shared.refresh()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 9) {
                    SpaceMarkBadge(mood: content.mood, reactive: true).frame(width: 22)
                    if let icon = content.icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(content.tint)
                    }
                    if voice.isActive {
                        VoiceWaveform(level: voice.level).frame(width: 18, height: 12)
                    }
                    Text(content.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let trailing = liveTrailing(content) {
                        Text(trailing)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(content.tint == .orange ? .orange : .gray)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: true, vertical: false)
                .background(Capsule(style: .continuous).fill(Space.black))
                .overlay(Capsule(style: .continuous).strokeBorder(Space.hairline, lineWidth: 0.75))
                .shadow(color: content.glow, radius: 10)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            }
        }
        .buttonStyle(.plain)
    }

    /// Clocks tick, so they're recomputed every second rather than taken from `content`.
    private func liveTrailing(_ content: Content) -> String? {
        if agent.isBusy, let started = agent.taskStartedAt, agent.permissions.isEmpty, manager.quickResult == nil, !voice.isActive {
            return AgentActivityView.clock(Date().timeIntervalSince(started))
        }
        if let timer = timers.next, content.icon == "timer" { return AgentTimers.format(timer.end.timeIntervalSinceNow) }
        return content.trailing
    }
}
