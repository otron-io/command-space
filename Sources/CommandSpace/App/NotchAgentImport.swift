//
//  NotchAgentImport.swift
//  Command Space
//
//  Command Space grew out of Notch Agent. If Notch Agent is installed, this brings its agent
//  settings over: System One/Two choices, voice and whistle patterns, Spotify, learned
//  actions, the Snap 1 model and saved keys. Notch Agent itself is left alone; the two only
//  conflict over push-to-talk and whistling, so it offers to quit it.
//

import AppKit
import Defaults
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.commandspace", category: "import")

extension Defaults.Keys {
    static let importedNotchAgent = Key<Bool>("importedNotchAgent", default: false)
}

@MainActor
enum NotchAgentImport {
    static let bundleID = "io.otron.notchagent"

    private static var container: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(bundleID)/Data")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: container.path)
            || !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The agent's settings; nothing about the notch itself.
    private static let keys = [
        "agentServerURL", "agentModelURL", "agentModelOverride",
        "pushToTalkKey", "pushToTalkDucking",
        "whistleTrigger", "whistlePattern", "whistleCommands",
        "spotifyClientID",
        "jevModel", "jevInstantActions", "jevAmbientNudges", "jevSmartSuggestions", "jevDoneCheck",
        "decisionBackend", "layaManifestURL",
    ]

    /// Returns a one-line summary of what came over.
    @discardableResult
    static func run() -> String {
        var imported: [String] = []

        let prefsURL = container.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        if let data = FileManager.default.contents(atPath: prefsURL.path),
           let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            var count = 0
            for key in keys {
                guard let value = prefs[key] else { continue }
                UserDefaults.standard.set(value, forKey: key)
                count += 1
            }
            if count > 0 { imported.append("\(count) settings") }
        }

        // Learned actions and the Snap 1 model (copies are APFS clones, so the model costs no space).
        let fm = FileManager.default
        let oldSupport = container.appendingPathComponent("Library/Application Support/NotchAgent")
        let newSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CommandSpace")
        try? fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
        for item in ["learned-actions.json", "Laya"] {
            let source = oldSupport.appendingPathComponent(item)
            let target = newSupport.appendingPathComponent(item)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.copyItem(at: source, to: target)) != nil {
                imported.append(item == "Laya" ? "Snap 1" : "learned actions")
            }
        }

        // Keys. macOS may ask once to let Command Space read Notch Agent's keychain items.
        if JevKeychain.load() == nil, let jev = readKeychain(service: "io.otron.notch.jev", account: "api-key") {
            JevKeychain.save(jev)
            imported.append("Jev key")
        }
        if SpotifyKeychain.load() == nil, let token = readKeychain(service: "io.otron.notch.spotify", account: "refresh-token") {
            SpotifyKeychain.save(token)
            imported.append("Spotify")
        }

        Defaults[.importedNotchAgent] = true
        LearnedActions.shared.reload()
        LayaModelStore.shared.rescan()
        DecisionEngine.shared.warmUpLaya()
        let summary = imported.isEmpty ? "Nothing to import" : "Imported " + imported.joined(separator: ", ")
        log.notice("\(summary, privacy: .public)")
        return summary
    }

    static func quitNotchAgent() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    private static func readKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
