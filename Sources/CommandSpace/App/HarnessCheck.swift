//
//  HarnessCheck.swift
//  Command Space
//
//  `CommandSpace --harness-check codex|claudeCode|opencode`: runs a two-turn conversation on one
//  harness without any UI and prints every event, approving each request once. For checking a
//  harness end to end (sign-in, streaming, approvals, resuming, history).
//

import AppKit
import Foundation

@MainActor
enum HarnessCheck {
    static func run(_ name: String) {
        guard let harness = SystemTwoHarness(rawValue: name) else {
            print("unknown harness \(name)"); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let backend: AgentBackend
        switch harness {
        case .opencode: backend = OpencodeBackend()
        case .codex: backend = CodexBackend()
        case .claudeCode: backend = ClaudeBackend()
        }
        var idle: CheckedContinuation<Void, Never>?
        var sawBusy = false
        AgentBackendSink.changed = { _ in print("· connection: \(backend.connection) model: \(backend.modelState)") }
        AgentBackendSink.event = { _, session, event in
            switch event {
            case .delta: return
            case .permission(let permission):
                print("· permission \(permission.permission): \(permission.patterns.joined()) → once")
                backend.reply(to: permission, with: .once)
            case .busy(let busy):
                print("· busy \(busy)")
                if busy { sawBusy = true } else if sawBusy { sawBusy = false; idle?.resume(); idle = nil }
            default:
                print("· \(String(describing: event).prefix(220))")
            }
            _ = session
        }
        backend.start()
        Task {
            do {
                let session = try await backend.createSession()
                print("· session \(session)")
                let turns = [
                    "Run `echo command-space-check > check.txt` in the shell, then reply with just: written.",
                    "What word did you write to the file? One word.",
                ]
                for (n, text) in turns.enumerated() {
                    print("== turn \(n + 1)")
                    try await backend.send(text, context: n == 0 ? "App: Finder" : nil, to: session)
                    await withCheckedContinuation { idle = $0 }
                }
                let snapshot = await backend.snapshot(of: session)
                print("== snapshot (\(snapshot?.items.count ?? 0) items, title: \(snapshot?.title ?? "-"))")
                for item in snapshot?.items ?? [] { print("  \(item.kind): \(item.text.prefix(120))") }
                let listed = await backend.listSessions().contains { $0.id == session }
                print("== listed in history: \(listed)")
                await backend.delete(session)
                backend.stop()
                exit(0)
            } catch {
                print("!! \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
