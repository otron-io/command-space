//
//  HarnessCheck.swift
//  Command Space
//
//  `CommandSpace --harness-check codex|claudeCode|opencode [mode]`: runs a two-turn conversation on one
//  harness without any UI and prints every event, approving each request once. For checking a
//  harness end to end (sign-in, streaming, approvals, resuming, history).
//

import AppKit
import Foundation

@MainActor
enum HarnessCheck {
    /// A synthetic image proves multimodal delivery without capturing or uploading the user's screen.
    static func runImage(_ name: String) {
        guard let harness = SystemTwoHarness(rawValue: name) else { print("unknown harness \(name)"); exit(2) }
        let backend: AgentBackend
        switch harness {
        case .opencode: backend = OpencodeBackend()
        case .codex: backend = CodexBackend()
        case .claudeCode: backend = ClaudeBackend()
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let code = "COMET-\(Int.random(in: 10...99))"
        let image = NSImage(size: NSSize(width: 640, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 200)).fill()
        (code as NSString).draw(at: NSPoint(x: 50, y: 70), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let bytes = bitmap.representation(using: .png, properties: [:]) else { print("could not generate image"); exit(1) }
        let context = AgentRequestContext("A synthetic test image is attached.", image: ScreenImage(data: bytes, mimeType: "image/png"))
        var completed = false
        var sawBusy = false
        var failure: String?
        AgentBackendSink.changed = { _ in }
        AgentBackendSink.event = { _, _, event in
            switch event {
            case .busy(let busy):
                if busy { sawBusy = true } else if sawBusy { completed = true }
            case .error(let text): failure = text; completed = true
            case .permission(let permission): backend.reply(to: permission, with: .reject)
            default: break
            }
        }
        backend.start()
        Task {
            var session: String?
            do {
                let id = try await backend.createSession()
                session = id
                print("image check · \(harness.name) · session \(id)")
                try await backend.send("Read the code printed in the attached image. Reply with just that code. Do not use tools.",
                                       context: context, mode: .ask, to: id)
                let deadline = Date().addingTimeInterval(120)
                while !completed && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
                let snapshot = await backend.snapshot(of: id)
                let answer = snapshot?.items.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n") ?? ""
                let matched = completed && failure == nil && answer.contains(code)
                print("expected: \(code); answer: \(answer.prefix(200)); matched: \(matched)")
                if let failure { print("error: \(failure)") }
                await backend.delete(id)
                backend.stop()
                exit(matched ? 0 : 1)
            } catch {
                if let session { await backend.delete(session) }
                backend.stop()
                print("image check failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    static func run(_ name: String, mode: AgentMode = .ask) {
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
        var current = mode
        AgentBackendSink.changed = { _ in print("· connection: \(backend.connection) model: \(backend.modelState)") }
        AgentBackendSink.event = { _, session, event in
            switch event {
            case .delta: return
            case .permission(let permission):
                print("· permission \(permission.permission): \(permission.plan.map { "PLAN " + $0.prefix(200) } ?? permission.patterns.joined()) → once")
                backend.reply(to: permission, with: .once)
            case .busy(let busy):
                print("· busy \(busy)")
                if busy { sawBusy = true } else if sawBusy { sawBusy = false; idle?.resume(); idle = nil }
            case .mode(let new):
                print("· mode → \(new.rawValue)")
                current = new
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
                    try await backend.send(text, context: n == 0 ? AgentRequestContext("App: Finder") : nil, mode: current, to: session)
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
