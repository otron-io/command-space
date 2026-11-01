//
//  JSONLineProcess.swift
//  Command Space
//
//  A child process that speaks newline-delimited JSON on stdin/stdout (Codex's app-server and
//  Claude Code's stream-json mode). Messages are delivered on the main actor, in order.
//

import Foundation

@MainActor
final class JSONLineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var stderrTail = ""
    private let onMessage: ([String: Any]) -> Void
    private let onExit: (Int32, String) -> Void

    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], environment: [String: String], directory: URL,
         onMessage: @escaping ([String: Any]) -> Void, onExit: @escaping (Int32, String) -> Void) {
        self.onMessage = onMessage
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func launch() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(chunk) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // Let any output still queued be delivered first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated {
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.errors.fileHandleForReading.readabilityHandler = nil
                self.onExit(status, self.stderrTail)
            } }
        }
        try process.run()
    }

    func send(_ message: [String: Any]) {
        guard process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.terminate()
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            onMessage(message)
        }
    }
}
