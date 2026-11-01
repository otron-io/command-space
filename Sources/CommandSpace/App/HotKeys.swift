//
//  HotKeys.swift
//  Command Space
//
//  ⌘Space opens Command Space. macOS gives that shortcut to Spotlight, so Command Space
//  turns Spotlight's shortcut off (the same switch as System Settings → Keyboard →
//  Keyboard Shortcuts → Spotlight) and can turn it back on.
//

import AppKit
import Defaults
import KeyboardShortcuts
import OSLog

private let log = Logger(subsystem: "io.otron.commandspace", category: "hotkey")

extension KeyboardShortcuts.Name {
    static let toggleCommandSpace = Self("toggleCommandSpace", default: .init(.space, modifiers: [.command]))
    /// Straight to the conversation with Space.
    static let askSpace = Self("askSpace", default: .init(.space, modifiers: [.option]))
}

extension Defaults.Keys {
    static let tookOverSpotlight = Key<Bool>("tookOverSpotlight", default: false)
}

enum SpotlightShortcut {
    /// Symbolic hotkey ids: 64 = "Show Spotlight search" (⌘Space), 65 = "Show Finder search window" (⌥⌘Space).
    private static let spotlightID = "64"
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    /// Whether Spotlight still owns ⌘Space.
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        guard let all = CFPreferencesCopyAppValue(key, domain) as? [String: Any],
              let entry = all[spotlightID] as? [String: Any] else { return true }  // absent = default = on
        if let enabled = entry["enabled"] as? Bool { return enabled }
        return (entry["enabled"] as? Int ?? 1) != 0
    }

    /// Turns Spotlight's ⌘Space off (or back on) and applies it without logging out.
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        let entry = """
        <dict><key>enabled</key><\(enabled ? "true" : "false")/><key>value</key><dict>\
        <key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array>\
        <key>type</key><string>standard</string></dict></dict>
        """
        let ok = run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", spotlightID, entry])
        // Makes the change take effect immediately.
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
        log.notice("spotlight shortcut enabled=\(enabled) ok=\(ok)")
        return ok && isEnabled == enabled
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
enum HotKeys {
    static func register() {
        KeyboardShortcuts.onKeyDown(for: .toggleCommandSpace) {
            Task { @MainActor in CommandPanelController.shared.toggle(mode: .search) }
        }
        KeyboardShortcuts.onKeyDown(for: .askSpace) {
            Task { @MainActor in CommandPanelController.shared.toggle(mode: .agent) }
        }
    }

    /// Re-registers after Spotlight lets go of ⌘Space, so the system hands the key to us.
    static func reregister() {
        KeyboardShortcuts.disable(.toggleCommandSpace)
        KeyboardShortcuts.enable(.toggleCommandSpace)
    }

    /// Takes ⌘Space from Spotlight, but only if the user agreed to it in onboarding or Settings
    /// (macOS updates sometimes switch Spotlight's shortcut back on).
    static func claimSpotlightShortcutIfAgreed() {
        guard Defaults[.tookOverSpotlight], SpotlightShortcut.isEnabled,
              KeyboardShortcuts.getShortcut(for: .toggleCommandSpace) == .init(.space, modifiers: [.command]) else { return }
        SpotlightShortcut.set(enabled: false)
        reregister()
    }

    /// Gives ⌘Space back to Spotlight.
    static func releaseSpotlightShortcut() {
        Defaults[.tookOverSpotlight] = false
        SpotlightShortcut.set(enabled: true)
    }
}
