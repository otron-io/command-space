//
//  PushToTalk.swift
//  Command Space
//
//  Hold a single modifier key (Right Option by default) to talk to the agent.
//  Audio starts on key-down so the first word isn't clipped; if another key is
//  pressed within the hold threshold, it was a shortcut and the audio is discarded.
//  Double-tap the key for continuous listening (every pause sends a command); tap to stop.
//

import AppKit
import Defaults
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.otron.commandspace", category: "voice")

enum PushToTalkKey: String, CaseIterable, Defaults.Serializable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn / Globe"
        case .off: return "Off"
        }
    }

    var shortName: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        case .fn: return "fn"
        case .off: return ""
        }
    }

    fileprivate var keyCode: UInt16? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .off: return nil
        }
    }

    fileprivate var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        case .off: return []
        }
    }
}

extension Defaults.Keys {
    static let pushToTalkKey = Key<PushToTalkKey>("pushToTalkKey", default: .rightOption)
    static let pushToTalkDucking = Key<Bool>("pushToTalkDucking", default: true)
}

extension Notification.Name {
    static let agentVoiceStarted = Notification.Name("agentVoiceStarted")
}

@MainActor
final class PushToTalk {
    static let shared = PushToTalk()

    /// Holds shorter than this are treated as taps/shortcuts and ignored.
    private let holdThreshold: TimeInterval = 0.1

    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var confirmed = false
    private var confirmTask: Task<Void, Never>?
    /// Volume before ducking, restored when the key is released.
    private var duckedFrom: Float32?
    /// Hands-free listening started by the whistle trigger.
    private var handsFreeTask: Task<Void, Never>?
    /// Presses shorter than this are taps (double-tap toggles continuous listening).
    private let tapLimit: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.45
    private var lastTapAt: Date?
    private var continuousTask: Task<Void, Never>?
    private var isContinuous: Bool { continuousTask != nil }

    private init() {}

    func start() {
        guard monitors.isEmpty else { return }
        VoiceInput.shared.warmUp()
        Task { await QuickActions.shared.refreshShortcuts() }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in PushToTalk.shared.handle(event) }
        }) {
            monitors.append(global)
        }
        // Also see events while the Command Space panel itself has keyboard focus.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in PushToTalk.shared.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let key = Defaults[.pushToTalkKey]
        guard let code = key.keyCode else { return }

        switch event.type {
        case .keyDown:
            // Another key during the threshold means it's a shortcut (e.g. ⌥-letter).
            if pressedAt != nil && !confirmed { abort() }
        case .flagsChanged where event.keyCode == code:
            let isDown = event.modifierFlags.contains(key.flag)
            if isDown {
                // Only start when the key is pressed on its own.
                let others = event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).subtracting(key.flag)
                guard others.isEmpty, pressedAt == nil else { return }
                keyDown()
            } else {
                keyUp()
            }
        case .flagsChanged:
            // A different modifier joined in before we confirmed: it's a chord, not push-to-talk.
            if pressedAt != nil && !confirmed { abort() }
        default:
            break
        }
    }

    private func keyDown() {
        // While listening continuously the key only matters as a tap (to stop).
        if isContinuous {
            pressedAt = Date()
            confirmed = false
            return
        }
        handsFreeTask?.cancel()
        handsFreeTask = nil
        pressedAt = Date()
        confirmed = false
        VoiceInput.shared.begin()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.holdThreshold ?? 0.1))
            guard let self, !Task.isCancelled, self.pressedAt != nil else { return }
            self.confirmed = true
            // Grab "this" (selection, window, page) and the app's menus before anything changes focus.
            if !CommandPanelController.shared.isVisible {
                ContextCapture.shared.begin(allowCopyFallback: true)
            }
            self.duck()
            NotificationCenter.default.post(name: .agentVoiceStarted, object: nil)
        }
    }

    private func keyUp() {
        guard let pressed = pressedAt else { return }
        pressedAt = nil
        confirmTask?.cancel()
        let isTap = Date().timeIntervalSince(pressed) < tapLimit
        if isContinuous {
            if isTap { stopContinuous() }
            return
        }
        if isTap {
            VoiceInput.shared.cancel()
            restoreVolume()
            confirmed = false
            if let last = lastTapAt, Date().timeIntervalSince(last) < doubleTapWindow {
                lastTapAt = nil
                startContinuous()
            } else {
                lastTapAt = Date()
            }
            return
        }
        lastTapAt = nil
        guard confirmed else {
            VoiceInput.shared.cancel()
            return
        }
        confirmed = false
        // Restore before running the command, so "volume to 75" isn't undone by the restore.
        restoreVolume()
        Task {
            let text = await VoiceInput.shared.end()
            guard !text.isEmpty else { return }
            log.notice("push-to-talk sending \(text.count) chars")
            AgentManager.shared.sendFromVoice(text)
        }
    }

    /// Listens without a key (after the whistle trigger) and sends once the speaker goes quiet.
    func listenHandsFree() {
        guard pressedAt == nil, !VoiceInput.shared.isActive else { return }
        VoiceInput.shared.begin()
        guard VoiceInput.shared.state == .listening else { return }
        // No ⌘C fallback: the user may be across the room, so don't type into the front app.
        if !CommandPanelController.shared.isVisible {
            ContextCapture.shared.begin(allowCopyFallback: false)
        }
        duck()
        NotificationCenter.default.post(name: .agentVoiceStarted, object: nil)
        handsFreeTask = Task { [weak self] in
            await Self.waitForEndOfSpeech()
            guard let self, !Task.isCancelled else { return }
            self.handsFreeTask = nil
            self.restoreVolume()
            let text = await VoiceInput.shared.end()
            guard !text.isEmpty else { return }
            log.notice("hands-free sending \(text.count) chars")
            AgentManager.shared.sendFromVoice(text)
        }
    }

    // MARK: Continuous

    private func startContinuous() {
        guard continuousTask == nil else { return }
        log.notice("continuous listening on")
        VoiceInput.shared.isContinuous = true
        NotificationCenter.default.post(name: .agentVoiceStarted, object: nil)
        continuousTask = Task { [weak self] in
            while !Task.isCancelled {
                VoiceInput.shared.begin()
                guard VoiceInput.shared.state == .listening else { break }  // no microphone access
                let heard = await Self.waitForEndOfSpeech(patient: true)
                guard !Task.isCancelled else { break }
                guard heard else {
                    // Long silence: restart the recognizer so sessions stay short.
                    VoiceInput.shared.cancel()
                    continue
                }
                let text = await VoiceInput.shared.end()
                guard !Task.isCancelled else { break }
                if Self.isStopPhrase(text) { break }
                guard !text.isEmpty else { continue }
                // One command at a time, each acting on whatever app is in front when it starts.
                while StepRunner.shared.isRunning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                if !CommandPanelController.shared.isVisible {
                    ContextCapture.shared.begin(allowCopyFallback: false)
                }
                log.notice("continuous sending \(text.count) chars")
                AgentManager.shared.sendFromVoice(text)
            }
            self?.finishContinuous()
        }
    }

    private func stopContinuous() {
        continuousTask?.cancel()
        VoiceInput.shared.cancel()
        finishContinuous()
    }

    private func finishContinuous() {
        guard continuousTask != nil else { return }
        continuousTask = nil
        VoiceInput.shared.isContinuous = false
        if VoiceInput.shared.state == .listening { VoiceInput.shared.cancel() }
        log.notice("continuous listening off")
    }

    nonisolated static func isStopPhrase(_ text: String) -> Bool {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["stop", "stop listening", "that's all", "that is all", "thats all", "done listening", "stop continuous"].contains(clean)
    }

    /// Ends when the transcript stops changing, or when nothing is said at all.
    /// - Parameter patient: wait up to a minute for speech to start (continuous mode).
    /// - Returns: whether anything was said.
    @discardableResult
    private static func waitForEndOfSpeech(patient: Bool = false) async -> Bool {
        let started = Date()
        var lastText = ""
        var lastChange = Date()
        while VoiceInput.shared.state == .listening, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let text = VoiceInput.shared.transcript
            if text != lastText {
                lastText = text
                lastChange = Date()
            }
            let elapsed = Date().timeIntervalSince(started)
            if text.isEmpty ? elapsed > (patient ? 50 : 4) : Date().timeIntervalSince(lastChange) > 1.0 { return !text.isEmpty }
            // Long dictation still gets cut into commands.
            if !text.isEmpty, Date().timeIntervalSince(lastChange) < 1.0, elapsed > (patient ? 60 : 12) { return true }
            if !patient, elapsed > 12 { return !text.isEmpty }
        }
        return !lastText.isEmpty
    }

    /// Halves the output volume while listening if something is playing, so you don't have to shout.
    private func duck() {
        guard Defaults[.pushToTalkDucking], MusicManager.shared.isPlaying, duckedFrom == nil else { return }
        let volume = VolumeManager.shared.currentVolume
        guard volume > 0.05 else { return }
        duckedFrom = volume
        VolumeManager.shared.setAbsoluteQuietly(volume * 0.5)
    }

    private func restoreVolume() {
        guard let volume = duckedFrom else { return }
        duckedFrom = nil
        VolumeManager.shared.setAbsoluteQuietly(volume)
    }

    private func abort() {
        lastTapAt = nil
        if isContinuous {
            // A shortcut with the talk key mustn't end the continuous session.
            pressedAt = nil
            return
        }
        restoreVolume()
        pressedAt = nil
        confirmed = false
        confirmTask?.cancel()
        VoiceInput.shared.cancel()
    }
}

struct PushToTalkKeyPicker: View {
    @Default(.pushToTalkKey) private var key

    var body: some View {
        Picker("Hold to talk:", selection: $key) {
            ForEach(PushToTalkKey.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        if key != .off {
            Text("Double-tap \(key.shortName) to keep listening: every pause runs a command. Tap once, or say “stop listening”, to end.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
