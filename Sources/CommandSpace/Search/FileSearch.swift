//
//  FileSearch.swift
//  Command Space
//
//  Files and folders by name, from the Spotlight index (so it's instant and needs no
//  indexing of its own). Results in the home folder, most recently used first.
//

import AppKit
import Foundation

struct FileHit: Identifiable, Hashable {
    let url: URL
    let name: String
    let isFolder: Bool
    let lastUsed: Date?
    var id: String { url.path }
}

@MainActor
final class FileSearch: NSObject {
    private var query: NSMetadataQuery?
    private var completion: (([FileHit]) -> Void)?
    private var currentText = ""

    /// Paths that are never interesting to open from a launcher.
    private static let noise = ["/Library/", "/.", "/node_modules/", "/.build/", "/DerivedData/", "/Caches/",
                                "/.Trash/", ".app/Contents/", "/build/", "/Pods/", "/.git/"]

    func search(_ text: String, limit: Int = 12, completion: @escaping ([FileHit]) -> Void) {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return completion([]) }
        currentText = trimmed
        self.completion = { hits in completion(Array(hits.prefix(limit))) }

        let query = NSMetadataQuery()
        // Words in any order: "q3 report" finds "Report Q3 final.pdf".
        let words = trimmed.split(separator: " ").map(String.init).prefix(4)
        let parts = words.map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*") }
        let notApp = NSPredicate(format: "NOT (%K == 'com.apple.application-bundle')", NSMetadataItemContentTypeKey)
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts + [notApp])
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        query.notificationBatchingInterval = 0.05
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)),
                                               name: .NSMetadataQueryGatheringProgress, object: query)
        self.query = query
        query.start()
    }

    func cancel() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: nil, object: query)
        self.query = nil
        completion = nil
    }

    @objc private func gathered(_ note: Notification) {
        guard let query, (note.object as? NSMetadataQuery) === query else { return }
        query.disableUpdates()
        var hits: [FileHit] = []
        let count = min(query.resultCount, 400)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if Self.noise.contains(where: path.contains) { continue }
            let url = URL(fileURLWithPath: path)
            let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            hits.append(FileHit(url: url,
                                name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent,
                                isFolder: type == "public.folder",
                                lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
            if hits.count >= 60 { break }
        }
        query.enableUpdates()
        // Names that start with the query first, then by recency (already sorted).
        let lowered = currentText.lowercased()
        let ranked = hits.enumerated().sorted { a, b in
            let pa = a.element.name.lowercased().hasPrefix(lowered), pb = b.element.name.lowercased().hasPrefix(lowered)
            return pa != pb ? pa : a.offset < b.offset
        }.map(\.element)
        completion?(ranked)
        if note.name == .NSMetadataQueryDidFinishGathering { cancel() }
    }
}
