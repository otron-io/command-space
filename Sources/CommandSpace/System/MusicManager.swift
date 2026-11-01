//
//  MusicManager.swift
//  Command Space
//
//  Just enough now-playing state and media control for the agent (boring.notch's full
//  MusicManager drove the notch's player UI; Command Space only needs to know whether
//  something is playing and to send play/pause/next/previous).
//
//  Control goes through the system media keys, so it works with any player. State is read
//  from Spotify or Music over AppleScript, only while one of them is running.
//

import AppKit
import Foundation

@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    @Published private(set) var isPlaying = false
    @Published private(set) var songTitle = ""
    @Published private(set) var artistName = ""

    private static let players: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]
    private static let queue = DispatchQueue(label: "io.otron.commandspace.nowplaying")
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in MusicManager.shared.refresh() }
        }
    }

    // MARK: Control

    func togglePlay() { MediaKeys.post(.playPause); refreshSoon() }
    func nextTrack() { MediaKeys.post(.next); refreshSoon() }
    func previousTrack() { MediaKeys.post(.previous); refreshSoon() }

    // MARK: State

    private func refreshSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
        }
    }

    /// Polls only players we're already allowed to script, so launching never pops an Automation prompt.
    /// `askIfNeeded` is for explicit requests ("what's playing?").
    func refresh(askIfNeeded: Bool = false) {
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        guard !running.isEmpty else {
            if isPlaying || !songTitle.isEmpty { isPlaying = false; songTitle = ""; artistName = "" }
            return
        }
        Self.queue.async {
            // Off the main thread: asking blocks until the user answers.
            let running = running.filter { Self.mayAutomate($0.bundleID, ask: askIfNeeded) }
            var found: (Bool, String, String)?
            for player in running {
                let script = """
                tell application "\(player.name)"
                  if player state is playing then
                    return "1" & linefeed & (name of current track) & linefeed & (artist of current track)
                  else
                    return "0" & linefeed & (name of current track) & linefeed & (artist of current track)
                  end if
                end tell
                """
                var error: NSDictionary?
                guard let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else { continue }
                let parts = out.components(separatedBy: "\n")
                let state = (parts.first == "1", parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
                if state.0 { found = state; break }
                if found == nil { found = state }
            }
            let result = found ?? (false, "", "")
            Task { @MainActor in
                let me = MusicManager.shared
                me.isPlaying = result.0
                me.songTitle = result.0 ? result.1 : ""
                me.artistName = result.0 ? result.2 : ""
            }
        }
    }
}

extension MusicManager {
    /// Whether we may send Apple events to the app (asks only when `ask` is true).
    nonisolated static func mayAutomate(_ bundleID: String, ask: Bool) -> Bool {
        var target = AEAddressDesc()
        let status: OSStatus = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        }
        return status == noErr
    }
}

/// Posts the hardware media keys (NX_KEYTYPE_*), which every player responds to.
enum MediaKeys {
    enum Key: Int32 {
        case playPause = 16  // NX_KEYTYPE_PLAY
        case next = 17       // NX_KEYTYPE_NEXT
        case previous = 18   // NX_KEYTYPE_PREVIOUS
    }

    static func post(_ key: Key) {
        func event(down: Bool) -> CGEvent? {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 8, data1: data1, data2: -1)?.cgEvent
        }
        event(down: true)?.post(tap: .cghidEventTap)
        event(down: false)?.post(tap: .cghidEventTap)
    }
}
