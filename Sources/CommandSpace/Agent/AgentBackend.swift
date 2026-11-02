//
//  AgentBackend.swift
//  Command Space
//
//  The contract between a conversation (`AgentThread`) and the harness running it. Each harness
//  translates its own wire format (opencode's SSE, Codex's JSON-RPC, Claude Code's stream-json)
//  into these events, so the panel, window and live pill don't know which one is in use.
//
//  Live events never carry the user's own messages: the thread adds those itself when sending,
//  so screen context sent alongside a request never shows up in the chat.
//

import Foundation

enum AgentEvent {
    /// Insert, or replace the item with the same id.
    case item(AgentItem)
    /// Append streamed text to an item, creating it if needed.
    case delta(id: String, text: String)
    case busy(Bool)
    case retry(AgentRetry?)
    /// The model started another step (one model call).
    case step
    case title(String)
    case error(String)
    case permission(AgentPermission)
    case permissionResolved(String)
    /// Tokens generated, and how long generating them took when known.
    case generated(tokens: Int, seconds: Double?)
    /// The harness changed the conversation's mode itself (e.g. after a plan was approved).
    case mode(AgentMode)
}

/// A conversation's state as stored by the harness.
struct AgentSnapshot {
    var items: [AgentItem]
    var permissions: [AgentPermission]
    var busy: Bool
    var title: String?
}

/// For a plan approval: once = approve, always = approve and accept edits, reject = keep planning.
enum PermissionReply: String {
    case once, always, reject
}

@MainActor
protocol AgentBackend: AnyObject {
    var harness: SystemTwoHarness { get }
    var connection: AgentConnection { get }
    /// What the welcome screen and activity view say about the model.
    var modelState: AgentModelState { get }

    /// Connect, or launch the harness. Safe to call repeatedly.
    func start()
    /// Disconnect and stop any processes this app launched.
    func stop()

    func createSession() async throws -> String
    /// `context` is what the user was looking at; harnesses send it without showing it.
    func send(_ text: String, context: AgentRequestContext?, mode: AgentMode, to session: String) async throws
    /// Switch a conversation's mode now (harnesses that apply modes per request can ignore it).
    func setMode(_ mode: AgentMode, for session: String)
    func abort(_ session: String)
    func reply(to permission: AgentPermission, with reply: PermissionReply)

    func listSessions() async -> [AgentSessionSummary]
    func snapshot(of session: String) async -> AgentSnapshot?
    func delete(_ session: String) async
    func refreshModelState()
}

/// How backends report back. Set by `AgentManager`.
@MainActor
enum AgentBackendSink {
    static var event: (SystemTwoHarness, String, AgentEvent) -> Void = { _, _, _ in }
    static var changed: (SystemTwoHarness) -> Void = { _ in }
}
