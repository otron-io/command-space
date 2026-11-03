//
//  CommandSpaceView.swift
//  Command Space
//
//  An OLED-black bubble that stretches into the search bar, with a second black card
//  growing underneath for results or the conversation with Space. Same visual language
//  as Notch Agent: pure black, white type, gray secondary text, soft white fills.
//

import AppKit
import Defaults
import SwiftUI

enum Space {
    static let barWidth: CGFloat = 680
    static let barHeight: CGFloat = 58
    static let rowHeight: CGFloat = 48
    static let maxRows = 8
    static let agentHeight: CGFloat = 400
    static let black = Color(red: 0, green: 0, blue: 0)
    static let hairline = Color.white.opacity(0.09)
}

struct CommandSpaceView: View {
    @ObservedObject var model: CommandSpaceModel
    @ObservedObject private var search: SearchEngine
    @ObservedObject private var agent = AgentManager.shared
    @ObservedObject private var voice = VoiceInput.shared
    @ObservedObject private var monitor = AmbientMonitor.shared
    @FocusState private var fieldFocused: Bool
    /// The field, placeholder and buttons only exist once the bubble has become the bar.
    @State private var showsContent = false

    init(model: CommandSpaceModel) {
        self.model = model
        _search = ObservedObject(wrappedValue: model.search)
    }

    var body: some View {
        VStack(spacing: 10) {
            // Chatting with Space reads like a chat: conversation above, input at the bottom.
            if chatLayout {
                cardIfShown
                attachmentStrip
                bar
            } else {
                bar
                attachmentStrip
                cardIfShown
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .onChange(of: model.stage) { _, stage in
            if stage == .bar {
                // Let the bubble stretch most of the way before the contents fade in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    guard model.stage == .bar else { return }
                    withAnimation(.easeOut(duration: 0.14)) { showsContent = true }
                }
            } else {
                // Gone at once on the way out, so nothing spills past the shrinking bubble.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showsContent = false }
            }
        }
        .frame(width: CommandPanelController.size.width, height: CommandPanelController.size.height, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.showsCard)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.mode)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.focusToken) { _, _ in focusField() }
        .onChange(of: showsContent) { _, shown in if shown { focusField() } }
    }

    private func focusField() {
        fieldFocused = true
        // Cursor at the end, not everything selected (so "Remind me to " can be finished).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    // MARK: Layout

    private var chatLayout: Bool { model.mode == .agent }

    @ViewBuilder
    private var cardIfShown: some View {
        if model.stage == .bar && model.showsCard {
            card
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.97, anchor: chatLayout ? .bottom : .top).combined(with: .opacity),
                    removal: .opacity))
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if showsContent {
            ImageAttachmentStrip(images: $model.attachments, error: model.pasteError)
        }
    }

    // MARK: Bar

    private var expanded: Bool { model.stage == .bar }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { model.mode == .agent ? (model.mode = .search) : model.askSpace() } label: {
                SpaceMarkBadge(mood: mood, reactive: true)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)
            .help(model.mode == .agent ? "Back to search (⇧⇥)" : "Ask Space (⇥)")
            if expanded && showsContent {
                field
                    .transition(.opacity)
                ScreenContextControl()
                    .transition(.opacity)
                trailing
                    .transition(.opacity)
            } else if expanded {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, expanded ? 16 : 0)
        .frame(width: expanded ? Space.barWidth : Space.barHeight, height: Space.barHeight)
        .background(Capsule(style: .continuous).fill(Space.black))
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(barStroke, lineWidth: voice.isActive ? 1.2 : 0.75))
        .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
        .opacity(model.stage == .hidden ? 0 : 1)
        .scaleEffect(model.stage == .hidden ? 0.6 : 1)
        .reportFrame { model.barFrame = $0 }
    }

    private var barStroke: Color {
        if voice.isActive { return Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.4 + 0.5 * Double(voice.level)) }
        if !agent.permissions.isEmpty { return .yellow.opacity(0.5) }
        return Space.hairline
    }

    private var field: some View {
        TextField(placeholder, text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($fieldFocused)
            .lineLimit(1)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.mode == .agent {
            HStack(spacing: 6) {
                if agent.isBusy {
                    barButton("stop.fill", help: "Stop") { agent.current.abort() }
                }
                AgentModeChip(thread: agent.current)
                barButton("clock.arrow.circlepath", help: "All conversations (⌘Y)") { model.showConversations() }
                if !agent.current.isEmpty {
                    barButton("macwindow", help: "Continue in a window (⌘O)") { model.openInWindow() }
                }
                barButton("square.and.pencil", help: "New conversation (⌘N)") { agent.newThread() }
                Text("Space")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.35)))
            }
        } else if voice.isActive {
            VoiceWaveform(level: voice.level).frame(width: 24, height: 16)
        } else if !model.query.isEmpty {
            Button { model.query = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var placeholder: String {
        if voice.isActive { return voice.transcript.isEmpty ? "Listening…" : voice.transcript }
        if !model.attachments.isEmpty { return "Ask about the image\(model.attachments.count == 1 ? "" : "s")…" }
        if model.mode == .agent {
            let key = Defaults[.pushToTalkKey]
            return key == .off ? "Ask Space anything…" : "Ask Space anything… or hold \(key.shortName)"
        }
        return "Search apps and documents, or ask Space…"
    }

    private var mood: SpaceMood {
        if voice.isActive { return .listening }
        if !agent.permissions.isEmpty { return .attention }
        if agent.isBusy { return .working }
        if case .offline = agent.connection, model.mode == .agent { return .offline }
        if model.mode == .search && !model.query.isEmpty && !SearchEngine.hasLocalAnswer(model.query) && !search.asksAboutScreen && search.intent == nil && DecisionEngine.shared.onDeviceAvailable {
            return .thinking
        }
        return .idle
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            if chatLayout { footer }
            ScreenContextStrip(query: model.attachments.isEmpty ? model.query : "")
            Group {
                switch model.mode {
                case .agent:
                    if agentIsFresh && !model.attachments.isEmpty {
                        Text("Describe the image, read its text, or ask a question.")
                            .font(.system(size: 13)).foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    } else {
                        AgentView(thread: agent.current, onPrefill: model.prefill)
                            .padding(14)
                            .frame(height: agentIsFresh ? 196 : Space.agentHeight)
                    }
                case .search:
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        AgentLiveStrip {
                            if let thread = agent.mostRelevantThread { agent.makeCurrent(thread) }
                            model.mode = .agent
                        }
                            .padding(10)
                    } else {
                        resultsList
                    }
                }
            }
            if !chatLayout { footer }
        }
        .frame(width: Space.barWidth)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Space.black))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Space.hairline, lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
        .reportFrame { model.cardFrame = $0 }
    }

    /// Nothing but the welcome and suggestions to show: keep the card snug.
    private var agentIsFresh: Bool {
        agent.current.items.isEmpty && !agent.current.isBusy && agent.current.permissions.isEmpty && monitor.nudge == nil
    }

    private var resultsList: some View {
        let rows = search.results
        let visible = CGFloat(min(max(rows.count, 1), Space.maxRows))
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                        ResultRow(result: result, index: index, selected: index == model.selection)
                            .id(result.id)
                            .onTapGesture { model.selection = index; model.perform(result) }
                            .onHover { if $0 { model.hovered(index) } }
                    }
                }
                .padding(8)
            }
            .frame(height: visible * (Space.rowHeight + 2) + 16)
            .onChange(of: model.selection) { _, index in
                guard rows.indices.contains(index) else { return }
                proxy.scrollTo(rows[index].id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerStatus
            Spacer(minLength: 8)
            if model.mode == .agent {
                hint("⏎", "Send"); hint("⇧⇥", "Mode"); hint("⌘O", "Window"); hint("⌘Y", "History"); hint("esc", "Back")
            } else if let selected = model.selectedResult {
                hint("⏎", Self.verb(for: selected))
                if selected.fileURL != nil { hint("⌘⏎", "Reveal") }
                if selected.kind != .ask { hint("⇥", "Ask Space") }
                if selected.kind != .web && selected.kind != .address { hint("⌥⏎", "Google") }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color.white.opacity(0.035))
    }

    @ViewBuilder
    private var footerStatus: some View {
        if model.mode == .search, let selected = model.selectedResult, selected.kind == .conversion || selected.kind == .calculation {
            Label(selected.kind == .conversion ? "Converter · on this Mac" : "Calculator · on this Mac", systemImage: "bolt.fill")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.cyan)
        } else if model.mode == .search, let intent = search.intent {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").foregroundStyle(snapGradient)
                Text("Snap 1 · \(Self.intentLabel(intent))" + (search.snapLatency.map { " · \(Int($0 * 1000)) ms" } ?? ""))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.gray)
            .help("Ranked on this Mac by Snap 1")
        } else {
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(statusText)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.gray)
            .lineLimit(1)
        }
    }

    private var snapGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var statusText: String {
        switch agent.connection {
        case .connected: return agent.isBusy ? "Space is working" : "System Two ready · \(agent.activeHarness.name)"
        case .connecting: return "Connecting to \(agent.activeHarness.name)…"
        case .offline: return "\(agent.activeHarness.name) offline · search and System One still work"
        }
    }

    private var statusColor: Color {
        switch agent.connection {
        case .connected: return agent.isBusy ? .yellow : .green
        case .connecting: return .gray
        case .offline: return .red
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.gray)
        }
    }

    static func verb(for result: SearchResult) -> String {
        switch result.kind {
        case .app, .document, .folder, .place, .setting, .address, .web: return "Open"
        case .command, .system, .shortcut:
            if case .resolved(.spotify) = result.action { return "Play" }
            return "Run"
        case .calculation, .conversion: return "Copy"
        case .ask: return "Ask"
        case .conversation: return "Continue"
        }
    }

    static func intentLabel(_ intent: String) -> String {
        switch intent {
        case "open_app": return "app"
        case "open_document": return "document"
        case "quick_open": return "quick open"
        case "command": return "command"
        case "calculate": return "math"
        case "ask": return "question for Space"
        case "web_search": return "web search"
        default: return intent
        }
    }
}

// MARK: - Rows

struct ResultRow: View {
    let result: SearchResult
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.kind == .ask ? "“\(result.title)”" : result.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(result.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if result.snapPick {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.85, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .help("Snap 1's pick")
            }
            if selected {
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.gray.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Space.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.11 : 0))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch result.icon {
        case .file(let url):
            Image(nsImage: IconCache.icon(for: url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .remote(let url, let rounded):
            RemoteArtwork(url: url)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: rounded ? 6 : 15, style: .continuous))
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.18)))
        case .mark:
            SpaceMarkBadge(mood: .idle)
                .frame(width: 26)
        }
    }
}

/// Album covers and artist photos, cached for the session.
struct RemoteArtwork: View {
    let url: URL
    @State private var image: NSImage?

    private static var cache: [URL: NSImage] = [:]

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(.gray)
            }
        }
        .task(id: url) {
            if let cached = Self.cache[url] { image = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url), let loaded = NSImage(data: data) else { return }
            if Self.cache.count > 300 { Self.cache.removeAll() }
            Self.cache[url] = loaded
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

// MARK: - Live strip

/// When the field is empty: what Space is doing (working, waiting for approval, last result).
struct AgentLiveStrip: View {
    @ObservedObject private var manager = AgentManager.shared
    private var agent: AgentThread { manager.mostRelevantThread ?? manager.current }
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                SpaceMarkBadge(mood: !agent.permissions.isEmpty ? .attention : (agent.isBusy ? .working : .idle), reactive: true)
                    .frame(width: 26)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer()
                Text("⇥").font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var line: String {
        if !agent.permissions.isEmpty { return "Space needs your approval" }
        if agent.isBusy {
            var parts = ["Working"]
            if agent.stepCount > 0 { parts.append("step \(agent.stepCount)") }
            if let started = agent.taskStartedAt { parts.append(AgentActivityView.clock(Date().timeIntervalSince(started))) }
            return parts.joined(separator: " · ")
        }
        if AmbientMonitor.shared.nudge != nil { return "Space has a suggestion" }
        return "Open the conversation"
    }
}

// MARK: - Helpers

private struct FrameReporter: ViewModifier {
    let onChange: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onChange(geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { _, frame in onChange(frame) }
            }
        )
    }
}

extension View {
    func reportFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        modifier(FrameReporter(onChange: onChange))
    }
}
