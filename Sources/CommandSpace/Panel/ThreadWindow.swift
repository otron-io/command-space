//
//  ThreadWindow.swift
//  Command Space
//
//  The conversations window: every thread with Space, and a roomy place to continue one.
//  Unlike the panel it's a regular window that stays until you close it (Command Space shows
//  in the Dock and ⌘Tab while it's open). Push-to-talk while it's in front continues the
//  conversation it shows.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ThreadWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ThreadWindowController()

    /// The conversation shown; nil is a new, empty one.
    @Published private(set) var thread: AgentThread?
    @Published var draft = ""
    @Published var focusToken = 0

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }
    var isKey: Bool { window?.isKeyWindow == true }

    func show(_ thread: AgentThread?) {
        select(thread)
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusToken += 1
        Task { await AgentManager.shared.refreshSessions() }
    }

    func select(_ thread: AgentThread?) {
        if let thread { AgentManager.shared.observe(thread) }
        self.thread = thread
        draft = ""
        focusToken += 1
        AgentManager.shared.permissionsChanged()
    }

    func newConversation() { select(nil) }

    /// An approval arrived for the conversation shown here.
    func bringForward() {
        guard let window else { return }
        window.orderFrontRegardless()
        NSApp.requestUserAttention(.informationalRequest)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let target = thread ?? AgentThread()
        if thread == nil { select(target) }
        target.send(text)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Conversations"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationsView(controller: self))
        window.center()
        window.setFrameAutosaveName("CommandSpaceConversations")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar app once no regular window is open.
        DispatchQueue.main.async {
            if !(SettingsWindowController.shared.window?.isVisible ?? false) {
                NSApp.setActivationPolicy(.accessory)
            }
            AgentManager.shared.permissionsChanged()
        }
    }
}

// MARK: - View

private struct ConversationsView: View {
    @ObservedObject var controller: ThreadWindowController
    @ObservedObject private var manager = AgentManager.shared
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
                .background(Color(white: 0.055))
            Rectangle().fill(Space.hairline).frame(width: 0.5)
            ConversationDetail(controller: controller, thread: controller.thread)
                .id(controller.thread?.id)
        }
        .background(Space.black)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button { controller.newConversation() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("New conversation")
            }
            .padding(.top, 44)  // clear the traffic lights
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.gray)
                TextField("Search", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.07)))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.gray)
                            .padding(.top, 10)
                            .padding(.leading, 8)
                        ForEach(group.sessions) { session in
                            SessionRow(session: session,
                                       live: liveThread(for: session.id),
                                       selected: controller.thread?.sessionID == session.id) {
                                controller.select(manager.thread(forSession: session.id))
                            }
                            .contextMenu {
                                Button("Continue in Command Space") {
                                    CommandPanelController.shared.show(mode: .agent, thread: manager.thread(forSession: session.id))
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if controller.thread?.sessionID == session.id { controller.newConversation() }
                                    manager.deleteSession(session.id)
                                }
                            }
                        }
                    }
                    if manager.sessions.isEmpty {
                        Text(manager.connection == .connected ? "No conversations yet." : "System Two is offline.")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                            .padding(.top, 20)
                            .padding(.leading, 8)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
    }

    private func liveThread(for sessionID: String) -> AgentThread? {
        manager.liveThreads.first { $0.sessionID == sessionID }
    }

    private struct Group {
        let title: String
        let sessions: [AgentSessionSummary]
    }

    private var groups: [Group] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let sessions = manager.sessions.filter { query.isEmpty || $0.displayTitle.lowercased().contains(query) }
        let calendar = Calendar.current
        var buckets: [(String, [AgentSessionSummary])] = [("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Earlier", [])]
        for session in sessions {
            let index: Int
            if calendar.isDateInToday(session.updated) { index = 0 }
            else if calendar.isDateInYesterday(session.updated) { index = 1 }
            else if session.updated > Date().addingTimeInterval(-7 * 86_400) { index = 2 }
            else { index = 3 }
            buckets[index].1.append(session)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, sessions: $0.1) }
    }
}

private struct SessionRow: View {
    let session: AgentSessionSummary
    let live: AgentThread?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.updated.formatted(.relative(presentation: .named)))
                        Text("·")
                        Image(systemName: session.harness.icon).font(.system(size: 8.5))
                        Text(session.harness.name)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let live, !live.permissions.isEmpty {
                    Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                } else if let live, live.isBusy {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : (hovering ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Conversation

private struct ConversationDetail: View {
    @ObservedObject var controller: ThreadWindowController
    let thread: AgentThread?

    var body: some View {
        VStack(spacing: 0) {
            if let thread {
                ThreadTranscript(thread: thread)
            } else {
                AgentWelcomeView(onSend: { text in
                    controller.draft = text
                    controller.send()
                }, onPrefill: { text in
                    controller.draft = text
                    controller.focusToken += 1
                })
                .padding(.horizontal, 40)
                .padding(.top, 60)
                .frame(maxWidth: 760)
                Spacer()
            }
            Composer(controller: controller, thread: thread)
        }
    }
}

private struct ThreadTranscript: View {
    @ObservedObject var thread: AgentThread
    @ObservedObject private var manager = AgentManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if thread.isLoading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        ForEach(thread.items) { item in
                            AgentRow(item: item).id(item.id)
                            if let summary = thread.runSummaries[item.id] {
                                AgentRunSummaryView(summary: summary)
                            }
                            if let followUp = thread.followUp, followUp.itemID == item.id {
                                FollowUpBanner(followUp: followUp, thread: thread)
                            }
                            if let offer = thread.learnOffer, offer.itemID == item.id {
                                LearnOfferCard(offer: offer, thread: thread)
                            }
                        }
                        if thread.isBusy {
                            AgentActivityView(thread: thread).id("busy")
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: thread.items) { _, _ in scrollToEnd(proxy) }
                .onChange(of: thread.isBusy) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
            if let permission = thread.permissions.first {
                PermissionCard(permission: permission, command: thread.command(for: permission)) { reply in
                    thread.reply(to: permission, with: reply)
                }
                .frame(maxWidth: 760)
                .frame(height: 150)
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: thread.permissions.first?.id)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SpaceMarkBadge(mood: mood, reactive: true)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.gray)
            }
            Spacer()
            if thread.isBusy {
                Button("Stop") { thread.abort() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Space.hairline).frame(height: 0.5) }
    }

    private var mood: SpaceMood {
        if !thread.permissions.isEmpty { return .attention }
        if thread.isBusy { return .working }
        if case .offline = harnessConnection { return .offline }
        return .idle
    }

    private var status: String {
        if !thread.permissions.isEmpty { return "Waiting for your approval" }
        if thread.isBusy { return "Working…" }
        if case .offline(let reason) = harnessConnection { return reason }
        return thread.ownedBySystemTwo ? "\(thread.harness.name) · everything here goes to the agent" : "New conversation"
    }

    /// The conversation's own harness, which may not be the one selected for new conversations.
    private var harnessConnection: AgentConnection {
        thread.ownedBySystemTwo ? manager.backend(thread.harness).connection : manager.connection
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target = thread.isBusy ? "busy" : thread.items.last?.id
        guard let target else { return }
        withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }
}

private struct Composer: View {
    @ObservedObject var controller: ThreadWindowController
    let thread: AgentThread?
    @ObservedObject private var voice = VoiceInput.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { controller.send() }
                .padding(.vertical, 4)
            Button { controller.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(canSend ? 1 : 0.3)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (⏎)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Space.hairline, lineWidth: 0.75))
        .frame(maxWidth: 760)
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
        .padding(.top, 8)
        .onAppear { focused = true }
        .onChange(of: controller.focusToken) { _, _ in focused = true }
    }

    private var canSend: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if voice.isActive { return voice.transcript.isEmpty ? "Listening…" : voice.transcript }
        return thread?.ownedBySystemTwo == true ? "Reply to Space…" : "Ask Space anything…"
    }
}
