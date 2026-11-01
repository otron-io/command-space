//
//  AppIndex.swift
//  Command Space
//
//  Every app in the usual folders, kept fresh by watching those folders.
//

import AppKit
import Foundation

struct AppEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    /// Other names to match: the bundle's file name if it differs from the display name, and its English name.
    let aliases: [String]
    var id: String { url.path }
}

@MainActor
final class AppIndex: ObservableObject {
    static let shared = AppIndex()

    @Published private(set) var apps: [AppEntry] = []

    private var lastScan = Date.distantPast
    private var scanning = false
    private var watchers: [DispatchSourceFileSystemObject] = []

    nonisolated static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications"),
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications/Chrome Apps.localized"),
        ]
    }()

    /// Apps that live outside the usual folders but people expect to find.
    nonisolated private static let extras = [
        "/System/Library/CoreServices/Finder.app",
    ]

    private init() {
        refresh(force: true)
        watch()
    }

    /// Rescans if it's been a while (called whenever the panel opens).
    func refresh(force: Bool = false) {
        guard !scanning, force || Date().timeIntervalSince(lastScan) > 120 else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                self.apps = found
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    func entry(forBundleID bundleID: String) -> AppEntry? {
        apps.first { $0.bundleID == bundleID }
    }

    nonisolated private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var results: [AppEntry] = []

        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { return }
            let bundle = Bundle(url: resolved)
            let info = bundle?.infoDictionary
            // Skip background-only helpers.
            if (info?["LSBackgroundOnly"] as? Bool) == true || (info?["LSBackgroundOnly"] as? String) == "1" { return }
            var name = fm.displayName(atPath: resolved.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let fileName = resolved.deletingPathExtension().lastPathComponent
            var aliases: [String] = []
            if fileName != name { aliases.append(fileName) }
            if let english = info?["CFBundleName"] as? String, english != name, english != fileName { aliases.append(english) }
            results.append(AppEntry(url: resolved, name: name, bundleID: bundle?.bundleIdentifier, aliases: aliases))
        }

        for root in roots {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                if child.pathExtension == "app" {
                    add(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          child.lastPathComponent != "Utilities" {
                    // One level of folders (e.g. /Applications/Setapp, /Applications/Microsoft Office).
                    let nested = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        extras.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }.forEach(add)
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func watch() {
        for root in Self.roots {
            let fd = open(root.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.refresh(force: true) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }
}

/// Icons, cached (NSWorkspace icon lookups cost a few ms each).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = cache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        if cache.count > 800 { cache.removeAll() }
        cache[url.path] = image
        return image
    }
}
