//
//  QuickOpen.swift
//  Command Space
//
//  Things you open by typing their name or address: websites, paths, the usual folders,
//  System Settings panes and a few system commands.
//

import AppKit
import Foundation

enum QuickOpen {
    // MARK: Places

    struct Place {
        let name: String
        let aliases: [String]
        let url: URL
    }

    static let places: [Place] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var list = [
            Place(name: "Home", aliases: ["~", home.lastPathComponent], url: home),
            Place(name: "Desktop", aliases: [], url: home.appendingPathComponent("Desktop")),
            Place(name: "Documents", aliases: ["docs"], url: home.appendingPathComponent("Documents")),
            Place(name: "Downloads", aliases: [], url: home.appendingPathComponent("Downloads")),
            Place(name: "Pictures", aliases: ["photos folder"], url: home.appendingPathComponent("Pictures")),
            Place(name: "Movies", aliases: ["videos"], url: home.appendingPathComponent("Movies")),
            Place(name: "Music Folder", aliases: [], url: home.appendingPathComponent("Music")),
            Place(name: "Applications Folder", aliases: [], url: URL(fileURLWithPath: "/Applications")),
            Place(name: "Trash", aliases: ["bin"], url: home.appendingPathComponent(".Trash")),
        ]
        if FileManager.default.fileExists(atPath: icloud.path) {
            list.append(Place(name: "iCloud Drive", aliases: ["icloud"], url: icloud))
        }
        let git = home.appendingPathComponent("Documents/Git")
        if FileManager.default.fileExists(atPath: git.path) {
            list.append(Place(name: "Git", aliases: ["repos", "code"], url: git))
        }
        return list
    }()

    // MARK: System Settings

    struct SettingsPane {
        let name: String
        let keywords: String
        let id: String
        var url: URL { URL(string: "x-apple.systempreferences:\(id)")! }
    }

    static let settingsPanes: [SettingsPane] = [
        .init(name: "Wi-Fi", keywords: "wifi wireless network internet", id: "com.apple.wifi-settings-extension"),
        .init(name: "Bluetooth", keywords: "headphones airpods devices", id: "com.apple.BluetoothSettings"),
        .init(name: "Network", keywords: "ethernet vpn internet", id: "com.apple.Network-Settings.extension"),
        .init(name: "Battery", keywords: "power energy charging", id: "com.apple.Battery-Settings.extension"),
        .init(name: "General", keywords: "about software update storage", id: "com.apple.systempreferences.GeneralSettings"),
        .init(name: "Software Update", keywords: "update upgrade macos", id: "com.apple.Software-Update-Settings.extension"),
        .init(name: "Storage", keywords: "disk space free", id: "com.apple.settings.Storage"),
        .init(name: "Appearance", keywords: "dark mode light accent", id: "com.apple.Appearance-Settings.extension"),
        .init(name: "Accessibility", keywords: "voiceover zoom", id: "com.apple.Accessibility-Settings.extension"),
        .init(name: "Control Center", keywords: "menu bar", id: "com.apple.ControlCenter-Settings.extension"),
        .init(name: "Desktop & Dock", keywords: "dock stage manager hot corners mission control", id: "com.apple.Desktop-Settings.extension"),
        .init(name: "Displays", keywords: "monitor resolution night shift brightness", id: "com.apple.Displays-Settings.extension"),
        .init(name: "Wallpaper", keywords: "background desktop picture", id: "com.apple.Wallpaper-Settings.extension"),
        .init(name: "Notifications", keywords: "alerts banners", id: "com.apple.Notifications-Settings.extension"),
        .init(name: "Sound", keywords: "volume output input speakers microphone", id: "com.apple.Sound-Settings.extension"),
        .init(name: "Focus", keywords: "do not disturb", id: "com.apple.Focus-Settings.extension"),
        .init(name: "Screen Time", keywords: "limits", id: "com.apple.Screen-Time-Settings.extension"),
        .init(name: "Lock Screen", keywords: "screensaver password sleep", id: "com.apple.Lock-Screen-Settings.extension"),
        .init(name: "Privacy & Security", keywords: "permissions accessibility microphone camera filevault", id: "com.apple.settings.PrivacySecurity.extension"),
        .init(name: "Touch ID & Password", keywords: "fingerprint login", id: "com.apple.Touch-ID-Settings.extension"),
        .init(name: "Users & Groups", keywords: "accounts login items", id: "com.apple.Users-Groups-Settings.extension"),
        .init(name: "Login Items", keywords: "startup launch at login", id: "com.apple.LoginItems-Settings.extension"),
        .init(name: "Keyboard", keywords: "shortcuts key repeat input sources", id: "com.apple.Keyboard-Settings.extension"),
        .init(name: "Trackpad", keywords: "gestures click scroll", id: "com.apple.Trackpad-Settings.extension"),
        .init(name: "Mouse", keywords: "scroll tracking", id: "com.apple.Mouse-Settings.extension"),
        .init(name: "Printers & Scanners", keywords: "print", id: "com.apple.Print-Scan-Settings.extension"),
        .init(name: "Sharing", keywords: "airdrop file screen sharing remote", id: "com.apple.Sharing-Settings.extension"),
        .init(name: "Time Machine", keywords: "backup", id: "com.apple.Time-Machine-Settings.extension"),
        .init(name: "Date & Time", keywords: "clock timezone", id: "com.apple.Date-Time-Settings.extension"),
        .init(name: "Siri", keywords: "apple intelligence assistant", id: "com.apple.Siri-Settings.extension"),
        .init(name: "Spotlight", keywords: "search", id: "com.apple.Spotlight-Settings.extension"),
    ]

    // MARK: System commands

    struct SystemCommand {
        let id: String
        let name: String
        let keywords: String
        let icon: String
        let run: @MainActor () -> Void
    }

    @MainActor
    static let systemCommands: [SystemCommand] = [
        .init(id: "sys.lock", name: "Lock Screen", keywords: "lock away", icon: "lock.fill") {
            // ⌃⌘Q
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)
                event?.flags = [.maskCommand, .maskControl]
                event?.post(tap: .cghidEventTap)
            }
        },
        .init(id: "sys.sleep", name: "Sleep", keywords: "sleep mac suspend", icon: "moon.zzz.fill") {
            shell("/usr/bin/pmset", ["sleepnow"])
        },
        .init(id: "sys.screensaver", name: "Start Screen Saver", keywords: "screensaver", icon: "sparkles.tv") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        },
        .init(id: "sys.restart", name: "Restart…", keywords: "reboot", icon: "arrow.clockwise.circle") {
            loginwindow("rrst")
        },
        .init(id: "sys.shutdown", name: "Shut Down…", keywords: "power off turn off", icon: "power") {
            loginwindow("rsdn")
        },
        .init(id: "sys.logout", name: "Log Out…", keywords: "sign out", icon: "rectangle.portrait.and.arrow.right") {
            loginwindow("logo")
        },
        .init(id: "sys.emptytrash", name: "Empty Trash…", keywords: "trash bin delete", icon: "trash") {
            // Finder asks for confirmation (with its own warning) before emptying.
            appleScript(#"tell application "Finder" to empty trash"#)
        },
        .init(id: "sys.ejectall", name: "Eject All Disks", keywords: "unmount drives", icon: "eject.fill") {
            appleScript(#"tell application "Finder" to eject (every disk whose ejectable is true)"#)
        },
    ]

    /// Sends a loginwindow Apple event; these show the system's own confirmation dialog.
    private static func loginwindow(_ code: String) {
        appleScript("tell application \"loginwindow\" to «event aevt\(code)»")
    }

    private static func appleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    private static func shell(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try? process.run()
    }

    // MARK: Addresses and paths

    /// "github.com", "https://…", "localhost:3000" → a URL to open.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.count >= 4 else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "file", "mailto"].contains(scheme) || (url.host != nil && scheme.count > 1) {
            return url
        }
        let hostPattern = #"^(localhost|(\d{1,3}\.){3}\d{1,3}|([a-z0-9-]+\.)+[a-z]{2,})(:\d+)?(/\S*)?$"#
        guard trimmed.lowercased().range(of: hostPattern, options: .regularExpression) != nil else { return nil }
        // "report.pdf" is a file name, not a website.
        let host = trimmed.lowercased().split(separator: "/").first.map(String.init) ?? trimmed
        let tld = host.split(separator: ":").first?.split(separator: ".").last.map(String.init) ?? ""
        if fileExtensions.contains(tld) { return nil }
        let isLocal = trimmed.hasPrefix("localhost") || trimmed.first?.isNumber == true
        return URL(string: (isLocal ? "http://" : "https://") + trimmed)
    }

    /// "~/Doc", "/usr/lo" → the path itself if it exists, then matching entries in its folder.
    static func pathMatches(_ text: String, limit: Int = 6) -> [URL] {
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return [] }
        let expanded = (text as NSString).expandingTildeInPath
        let fm = FileManager.default
        var results: [URL] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            results.append(URL(fileURLWithPath: expanded))
            if isDir.boolValue && text.hasSuffix("/") {
                let children = (try? fm.contentsOfDirectory(atPath: expanded)) ?? []
                results += children.filter { !$0.hasPrefix(".") }.sorted().prefix(limit - 1)
                    .map { URL(fileURLWithPath: expanded).appendingPathComponent($0) }
            }
            return results
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        let partial = (expanded as NSString).lastPathComponent.lowercased()
        let children = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
        return children.filter { $0.lowercased().hasPrefix(partial) && !$0.hasPrefix(".") }
            .sorted().prefix(limit).map { URL(fileURLWithPath: parent).appendingPathComponent($0) }
    }

    private static let fileExtensions: Set<String> = [
        "pdf", "txt", "doc", "docx", "rtf", "md", "png", "jpg", "jpeg", "gif", "heic", "svg", "psd", "key", "pages",
        "numbers", "xls", "xlsx", "csv", "ppt", "pptx", "zip", "dmg", "pkg", "mov", "mp4", "mp3", "wav", "m4a",
        "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "sh", "rb", "go", "rs", "java", "kt", "cpp",
        "h", "m", "log", "plist", "xml", "sketch", "fig", "epub", "webp", "tiff",
    ]

    static func webSearchURL(_ query: String) -> URL? {
        // Strict encoding: "c++ & rust" must not turn into "c  " and a stray parameter.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let q = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://www.google.com/search?q=\(q)")
    }
}
