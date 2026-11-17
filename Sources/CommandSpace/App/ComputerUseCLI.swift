//
//  ComputerUseCLI.swift
//  Command Space
//
//  `CommandSpace --computer-use "task"` and `--computer-actions '<json>'`. If the app is running the
//  command forwards the task to it over the control channel and prints the stream it sends back;
//  otherwise (or with --standalone) this process drives Codex and the Mac itself, with no UI.
//  Both sides speak the same one-JSON-object-per-line messages:
//    status / action / approval / message / error, and always last: done.
//

import AppKit
import Combine
import Defaults
import Foundation

@MainActor
enum ComputerUseCLI {
    static let usage = """
    usage: CommandSpace --computer-use "task" [--model <id>] [--mode plan|ask|acceptEdits|auto|fullAccess] [--standalone] [--json] [--timeout <seconds>]
           CommandSpace --computer-actions '<json>' [--save /absolute/path.jpg]
    """

    // MARK: Arguments

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    private static func fail(usage message: String? = nil) -> Never {
        if let message { fputs("\(message)\n", stderr) }
        fputs(usage + "\n", stderr)
        exit(2)
    }

    // MARK: Printing (client side and standalone)

    /// The agent's latest message, held back until we know whether it is the answer or commentary along the way.
    private static var heldMessage: String?
    private static var lastActionLine = ""

    /// The final answer goes to stdout (so `answer=$(CommandSpace --computer-use …)` is just the answer); the rest is short lines on stderr. With --json everything is raw on stdout.
    private static func print(_ message: [String: Any], json: Bool) {
        if json {
            guard JSONSerialization.isValidJSONObject(message),
                  let data = try? JSONSerialization.data(withJSONObject: message),
                  let line = String(data: data, encoding: .utf8) else { return }
            Swift.print(line)
            return
        }
        let text = message["text"] as? String ?? ""
        let type = message["type"] as? String
        // Anything after a message means that message was commentary, not the answer.
        if type != "done", let earlier = heldMessage {
            fputs("  \(earlier)\n", stderr)
            heldMessage = nil
        }
        switch type {
        case "message":
            heldMessage = text
        case "done":
            if let answer = heldMessage { Swift.print(answer) }
            heldMessage = nil
        case "action":
            let status = message["status"] as? String
            let line = "\(message["tool"] as? String ?? "tool")  \(text)"
            // A step is announced when it starts; finishing it only matters if it failed.
            if status == "completed", line == lastActionLine { break }
            lastActionLine = line
            fputs("\(status == "error" ? "!" : "·") \(line)\n", stderr)
        case "status": fputs("· \(text)\n", stderr)
        case "approval": fputs("? \(text.isEmpty ? "waiting for approval…" : text)\n", stderr)
        case "error": fputs("! \(text)\n", stderr)
        default: break
        }
    }

    private static func headlessApp() {
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Installs a main-queue SIGINT handler; the source must stay alive.
    private static var interrupt: DispatchSourceSignal?
    private static func onInterrupt(_ handler: @escaping @MainActor () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        interrupt = source
    }

    /// Without the permissions the tool can't work: say which, and why this process (not the app) needs them.
    private static func preflight() {
        guard !ComputerAccess.ready else { return }
        let missing = ComputerAccess.missing
        fputs("Computer use needs macOS permissions that aren't granted yet:\n", stderr)
        for requirement in missing { fputs("  - \(requirement.title): \(requirement.reason)\n", stderr) }
        fputs("""
        This run is happening in your terminal, so macOS asks for them for the terminal app you started it
        from (Terminal, iTerm, …). System Settings → Privacy & Security is opening: switch that app on
        there, then run the command again.
        Or keep Command Space open: the command then hands the task to the app, which uses its own permissions.

        """, stderr)
        for requirement in missing { ComputerAccess.request(requirement) }
        usleep(300_000)  // let System Settings get the request before this process is gone
        exit(3)
    }

    // MARK: --computer-use

    static func run(arguments args: [String]) -> Never {
        guard let flag = args.firstIndex(of: "--computer-use"), args.count > flag + 1,
              !args[flag + 1].hasPrefix("--"), !args[flag + 1].trimmingCharacters(in: .whitespaces).isEmpty else {
            fail()
        }
        let task = args[flag + 1]
        var mode: AgentMode?
        if let raw = value(of: "--mode", in: args) {
            guard let parsed = AgentMode(rawValue: raw) else { fail(usage: "unknown mode “\(raw)”") }
            mode = parsed
        } else if args.contains("--mode") {
            fail(usage: "--mode needs a value")
        }
        let model = value(of: "--model", in: args)
        let json = args.contains("--json")
        var timeout: Double = 900
        if args.contains("--timeout") {
            guard let raw = value(of: "--timeout", in: args), let parsed = Double(raw),
                  parsed.isFinite, parsed > 0, parsed <= Double(Int64.max) / 1_000_000_000 else {
                fail(usage: "--timeout needs a finite positive number of seconds")
            }
            timeout = parsed
        }

        headlessApp()
        if !args.contains("--standalone"), ControlClient.isServerRunning() {
            forward(task: task, model: model, mode: mode, json: json, timeout: timeout)
        } else {
            let run = StandaloneRun(task: task, model: model, mode: mode, json: json, timeout: timeout)
            standalone = run
            Task { await run.start() }
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static var standalone: StandaloneRun?

    /// Hands the task to the running app and prints what it streams back.
    private static func forward(task: String, model: String?, mode: AgentMode?, json: Bool, timeout: Double) {
        var request: [String: Any] = ["command": "computer-use", "task": task]
        if let model { request["model"] = model }
        if let mode { request["mode"] = mode.rawValue }
        onInterrupt {
            ControlClient.disconnect()  // the app treats the disconnect as "stop"
            exit(130)
        }
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            ControlClient.disconnect()
            print(["type": "error", "text": "Timed out"], json: json)
            print(["type": "done", "ok": false], json: json)
            exit(124)
        }
        Task {
            do {
                try await ControlClient.run(request) { message in
                    print(message, json: json)
                    if message["type"] as? String == "done" {
                        exit((message["ok"] as? Bool ?? false) ? 0 : 1)
                    }
                }
            } catch {
                print(["type": "error", "text": "Command Space isn't accepting connections"], json: json)
                print(["type": "done", "ok": false], json: json)
                exit(1)
            }
            print(["type": "error", "text": "Command Space disconnected before the task finished"], json: json)
            print(["type": "done", "ok": false], json: json)
            exit(1)
        }
    }

    // MARK: --computer-actions

    /// Debugging aid: runs tool actions directly, with no model.
    static func runActions(arguments args: [String]) -> Never {
        guard let json = value(of: "--computer-actions", in: args) else { fail() }
        let save = value(of: "--save", in: args)
        headlessApp()
        ComputerTool.shared.headless = true
        _ = AppIndex.shared
        preflight()
        ComputerTool.shared.grantConversation("cli")
        Task {
            let result = await ComputerTool.shared.call(arguments: json, session: "cli", harness: .codex, mode: .fullAccess)
            Swift.print(result.text)
            if let save, let image = result.image {
                do {
                    try image.data.write(to: URL(fileURLWithPath: save))
                    fputs("\(save)\n", stderr)
                } catch {
                    fputs("! couldn't save image: \(error.localizedDescription)\n", stderr)
                }
            }
            exit(result.success ? 0 : 1)
        }
        NSApplication.shared.run()
        exit(0)
    }

    // MARK: Standalone runner

    /// This process drives Codex and the Mac itself.
    @MainActor
    private final class StandaloneRun {
        let task: String
        let model: String?
        let mode: AgentMode
        let json: Bool
        let timeout: Double

        private let backend = CodexBackend()
        private var session = ""
        private var sawBusy = false
        private var sendCompleted = false
        private var idleAfterBusy = false
        private var failed = false
        /// The user pressed esc: report it as a stop (exit 130, like ⌃C), not as a failure.
        private var stoppedByUser = false
        private var finished = false
        private var sentTools: Set<String> = []
        private var sentText: Set<String> = []

        init(task: String, model: String?, mode: AgentMode?, json: Bool, timeout: Double) {
            self.task = task
            self.model = model
            self.mode = mode ?? SystemTwoHarness.codex.defaultMode
            self.json = json
            self.timeout = timeout
        }

        private func emit(_ message: [String: Any]) { ComputerUseCLI.print(message, json: json) }

        func start() async {
            ComputerTool.shared.headless = true
            _ = AppIndex.shared
            ComputerUseCLI.preflight()

            AgentBackendSink.changed = { _ in }
            AgentBackendSink.event = { [weak self] _, _, event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            ComputerUseCLI.onInterrupt { [self] in
                stoppedByUser = true
                backend.abort(session)
                finish(code: 130)
            }
            Task { [timeout] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !finished else { return }
                backend.abort(session)
                finish(error: "Timed out", code: 124)
            }
            backend.start()
            let chosen = model ?? Defaults[.computerUseModel]
            do {
                session = try await backend.createSession(model: chosen.isEmpty ? nil : chosen)
            } catch {
                finish(error: error.localizedDescription, code: 1)
                return
            }
            guard !finished else { return }
            emit(["type": "status", "text": "Started · \(chosen.isEmpty ? "Codex default model" : chosen)"])
            // Running this command is the user's approval for control.
            ComputerTool.shared.grantConversation(session)
            ComputerTool.shared.onStop = { [weak self, backend] in
                self?.stoppedByUser = true
                self?.emit(["type": "status", "text": "Stopped (esc)"])
                backend.abort($0)
            }
            emit(["type": "status", "text": "esc stops it"])

            do {
                try await backend.send(task, context: nil, mode: mode, to: session)
                sendCompleted = true
                if idleAfterBusy { finish() }
            } catch {
                if stoppedByUser { finish(code: 130) }
                else { finish(error: error.localizedDescription, code: 1) }
            }
        }

        private func finish(error: String? = nil, code: Int32? = nil) {
            guard !finished else { return }
            finished = true
            let status = code ?? (stoppedByUser ? 130 : failed ? 1 : 0)
            backend.stop()
            Task {
                await ComputerTool.shared.waitForBatchToFinish()
                if let error { emit(["type": "error", "text": error]) }
                emit(["type": "done", "ok": status == 0])
                exit(status)
            }
        }

        private func handle(_ event: AgentEvent) {
            guard !finished else { return }
            switch event {
            case .item(let item):
                switch item.kind {
                case .tool(let name, let status):
                    guard sentTools.insert("\(item.id)|\(status)").inserted else { return }
                    let wire: String
                    switch status {
                    case "completed": wire = "completed"
                    case "error", "failed": wire = "error"
                    default: wire = "running"
                    }
                    emit(["type": "action", "tool": name, "text": item.text, "status": wire])
                case .assistant:
                    guard !item.text.isEmpty, sentText.insert("\(item.id)|\(item.text)").inserted else { return }
                    emit(["type": "message", "text": item.text])
                default: break
                }
            case .error(let text):
                failed = true
                emit(["type": "error", "text": text])
            case .permission(let permission):
                ask(permission)
            case .busy(let busy):
                if busy {
                    sawBusy = true
                    idleAfterBusy = false
                } else if sawBusy {
                    idleAfterBusy = true
                    if sendCompleted { finish() }
                }
            default: break
            }
        }

        /// Shell commands and file edits in modes that ask (control itself is pre-granted).
        private func ask(_ permission: AgentPermission) {
            let patterns = permission.patterns.joined(separator: ", ")
            guard isatty(0) != 0 else {
                backend.reply(to: permission, with: .reject)
                emit(["type": "status", "text": "Denied \(permission.permission) (not a terminal; use --mode fullAccess to allow commands)"])
                return
            }
            fputs("? Allow \(permission.permission): \(patterns)  [y]es / [a]lways / [N]o\n", stderr)
            // Never block the main actor on stdin.
            DispatchQueue.global().async { [backend] in
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let reply: PermissionReply = answer.hasPrefix("a") ? .always : answer.hasPrefix("y") ? .once : .reject
                DispatchQueue.main.async { MainActor.assumeIsolated { backend.reply(to: permission, with: reply) } }
            }
        }
    }

    // MARK: App side

    /// Called by `ControlServer` for each request from a command-line client.
    static func serve(_ request: [String: Any], on connection: ControlConnection) {
        switch request["command"] as? String {
        case "ping":
            connection.send(["type": "pong"])
            connection.close()
        case "computer-use":
            let task = (request["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !task.isEmpty else {
                reject(connection)
                return
            }
            let thread = AgentManager.shared.startComputerUse(
                task, model: request["model"] as? String,
                mode: (request["mode"] as? String).flatMap(AgentMode.init(rawValue:)))
            ThreadStream.begin(thread, on: connection)
        default:
            reject(connection)
        }
    }

    private static func reject(_ connection: ControlConnection) {
        connection.send(["type": "error", "text": "Unknown command"])
        connection.send(["type": "done", "ok": false])
        connection.close()
    }

    /// Streams one thread to one client until the task ends or the client leaves.
    @MainActor
    private final class ThreadStream {
        private static var active: [UUID: ThreadStream] = [:]

        static func begin(_ thread: AgentThread, on connection: ControlConnection) {
            let stream = ThreadStream(thread: thread, connection: connection)
            active[stream.id] = stream
            stream.start()
        }

        private let id = UUID()
        private let thread: AgentThread
        private let connection: ControlConnection
        private var observation: AnyCancellable?
        private var scheduled = false
        private var started = false
        private var failed = false
        private var closed = false
        private var idleCheck: Task<Void, Never>?
        private var sentTools: Set<String> = []
        private var sentText: Set<String> = []
        private var sentErrors: Set<String> = []
        private var sentPermissions: Set<String> = []

        init(thread: AgentThread, connection: ControlConnection) {
            self.thread = thread
            self.connection = connection
        }

        func start() {
            connection.onClose = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.thread.abort()  // the client pressed ⌃C
                    self.teardown()
                }
            }
            connection.send(["type": "status", "text": "Running in Command Space"])
            // objectWillChange fires before the change applies, so read on the next main-queue turn.
            observation = thread.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.scheduled else { return }
                    self.scheduled = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.scheduled = false; self.sync() } }
                }
            }
            sync()
        }

        private func sync() {
            guard !closed else { return }
            let items = thread.items
            let busy = thread.isBusy
            for (index, item) in items.enumerated() {
                switch item.kind {
                case .tool(let name, let status):
                    guard sentTools.insert("\(item.id)|\(status)").inserted else { continue }
                    let wire = status == "completed" ? "completed" : (status == "error" || status == "failed") ? "error" : "running"
                    connection.send(["type": "action", "tool": name, "text": item.text, "status": wire])
                case .assistant:
                    // Text streams in pieces: only send it once the thread is idle or something came after it.
                    guard !item.text.isEmpty, !busy || index < items.count - 1,
                          sentText.insert("\(item.id)|\(item.text)").inserted else { continue }
                    connection.send(["type": "message", "text": item.text])
                case .error:
                    guard sentErrors.insert(item.id).inserted else { continue }
                    failed = true
                    connection.send(["type": "error", "text": item.text])
                default: break
                }
            }
            for permission in thread.permissions where sentPermissions.insert(permission.id).inserted {
                connection.send(["type": "approval",
                                 "text": "Waiting for approval in Command Space: \(permission.permission) \(permission.patterns.joined(separator: ", "))"])
            }
            if busy || failed { started = true }
            if started && !busy {
                // Done once it has stayed idle for 400 ms (a task can go idle between steps).
                if idleCheck == nil {
                    idleCheck = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled, let self else { return }
                        self.idleCheck = nil
                        if !self.thread.isBusy { self.finish() }
                    }
                }
            } else {
                idleCheck?.cancel()
                idleCheck = nil
            }
        }

        private func finish() {
            sync()
            guard !closed else { return }
            connection.send(["type": "done", "ok": !failed])
            connection.close()
            teardown()
        }

        private func teardown() {
            closed = true
            idleCheck?.cancel()
            idleCheck = nil
            observation = nil
            connection.onClose = nil
            ThreadStream.active[id] = nil
        }
    }
}
