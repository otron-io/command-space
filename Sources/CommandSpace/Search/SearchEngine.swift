//
//  SearchEngine.swift
//  Command Space
//
//  Turns what you type into ranked results. Two passes:
//   1. instant: fuzzy matching over apps, places, settings, System One commands, plus
//      Spotlight's file index, addresses, paths and arithmetic;
//   2. Snap 1 (on this Mac): reads the query and the top candidates and decides what you're
//      after — an app, a document, a command or a question for the agent — and which result.
//      The list re-orders when it answers (typically well under 100 ms).
//

import AppKit
import Combine
import Defaults
import Foundation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.otron.commandspace", category: "search")

extension Defaults.Keys {
    static let searchFiles = Key<Bool>("searchFiles", default: true)
    static let searchSnapRanking = Key<Bool>("searchSnapRanking", default: true)
    static let searchWebFallback = Key<Bool>("searchWebFallback", default: true)
}

struct SearchResult: Identifiable, Equatable {
    enum Kind: String {
        case app, document, folder, place, setting, command, system, web, address, calculation, conversion, ask, shortcut, conversation

        var label: String {
            switch self {
            case .app: "Application"
            case .document: "Document"
            case .folder, .place: "Folder"
            case .setting: "System Settings"
            case .command: "Command"
            case .system: "System"
            case .web: "Web"
            case .address: "Open"
            case .calculation: "Calculator"
            case .conversion: "Converter"
            case .ask: "Ask Space"
            case .shortcut: "Shortcut"
            case .conversation: "Conversation"
            }
        }
    }

    enum Icon: Equatable {
        case file(URL)
        /// Artwork from the web (album covers); `rounded` false draws a circle (artists).
        case remote(URL, rounded: Bool)
        case symbol(String, Color)
        case mark
    }

    enum Action: Equatable {
        case open(URL)
        case command(id: String, standalone: Bool)
        case system(id: String)
        case copy(String)
        case ask(String)
        case shortcut(String)
        case conversation(id: String)
        /// A System One command with everything filled in from what was typed.
        case resolved(ResolvedCommand)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: Icon
    let action: Action
    var score: Double
    /// Snap 1 picked this one.
    var snapPick = false

    /// File-backed results can be revealed in Finder (⌘⏎) or have their path copied.
    var fileURL: URL? {
        if case .open(let url) = action, url.isFileURL { return url }
        return nil
    }
}

@MainActor
final class SearchEngine: ObservableObject {
    @Published private(set) var results: [SearchResult] = []
    /// What Snap 1 thinks the query is, once it has answered.
    @Published private(set) var intent: String?
    @Published private(set) var snapLatency: TimeInterval?

    private let files = FileSearch()
    private var fileHits: [FileHit] = []
    private var shortcuts: [String] = []
    private var currentQuery = ""
    private var snapTask: Task<Void, Never>?
    private var snapAnswer: (query: String, pick: String?, intent: String?, command: String?)?
    private var musicTask: Task<Void, Never>?
    private var music: (query: String, rows: [SearchResult])?

    private var appsObserver: AnyCancellable?
    private var contextObserver: AnyCancellable?

    init() {
        Task { shortcuts = await SystemBridge.shared.listShortcuts() }
        contextObserver = ContextCapture.shared.$captured.combineLatest(ContextCapture.shared.$choice)
            .dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, !self.currentQuery.isEmpty else { return }
                self.rebuild()
                self.scheduleSnap(for: self.currentQuery)
            }
        // The app index fills in the background; refresh results when it lands.
        appsObserver = AppIndex.shared.$apps.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, !self.currentQuery.isEmpty else { return }
            self.rebuild()
            self.scheduleSnap(for: self.currentQuery)
        }
    }

    func update(query raw: String) {
        let query = raw.trimmingCharacters(in: .whitespaces)
        currentQuery = query
        snapTask?.cancel()
        snapAnswer = nil
        intent = nil
        guard !query.isEmpty else {
            files.cancel()
            fileHits = []
            results = []
            return
        }
        let localAnswer = Self.hasLocalAnswer(query)
        if localAnswer { files.cancel(); fileHits = [] }
        fileHits = fileHits.filter { $0.name.lowercased().contains(query.lowercased().split(separator: " ").first.map(String.init) ?? "") }
        rebuild()
        if CommandPreview.detect(query).contains("play_music") { scheduleMusic(for: query) } else { musicTask?.cancel() }
        if Defaults[.searchFiles], query.count >= 2, QuickOpen.webURL(from: query) == nil, !localAnswer {
            files.search(query) { [weak self] hits in
                guard let self, self.currentQuery == query else { return }
                self.fileHits = hits
                self.rebuild()
                self.scheduleSnap(for: query)
            }
        }
        scheduleSnap(for: query)
    }

    // MARK: Candidates

    private func rebuild() {
        let query = currentQuery
        let q = query.lowercased()
        var list: [SearchResult] = []

        if let conversion = UnitConverter.evaluate(query) {
            list.append(.init(id: "convert", kind: .conversion, title: "= \(conversion.answer)",
                              subtitle: "\(conversion.source) · Converted on this Mac · ⏎ to copy",
                              icon: .symbol("arrow.left.arrow.right.square.fill", .cyan),
                              action: .copy(conversion.answer), score: 2))
        } else if let answer = UnitConverter.numberBase(query) {
            list.append(.init(id: "convert", kind: .conversion, title: "= \(answer)",
                              subtitle: "Number base · Converted on this Mac · ⏎ to copy",
                              icon: .symbol("number.square.fill", .cyan), action: .copy(answer), score: 2))
        }
        // Arithmetic first: if it parses, that's what was meant.
        if let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            list.append(.init(id: "calc", kind: .calculation, title: "= \(text)", subtitle: "Press ⏎ to copy",
                              icon: .symbol("equal.square.fill", .orange), action: .copy(text), score: 1.2))
        }
        if let url = QuickOpen.webURL(from: query) {
            list.append(.init(id: "url:\(url.absoluteString)", kind: .address, title: "Open \(url.host ?? url.absoluteString)",
                              subtitle: url.absoluteString, icon: .symbol("globe", .blue), action: .open(url), score: 1.1))
        }
        for (index, url) in QuickOpen.pathMatches(query).enumerated() {
            list.append(.init(id: url.path, kind: .folder, title: url.lastPathComponent, subtitle: abbreviate(url),
                              icon: .file(url), action: .open(url), score: 1.05 - Double(index) * 0.01))
        }

        for app in AppIndex.shared.apps {
            let best = ([app.name] + app.aliases).map { FuzzyMatch.score(q, in: $0) }.max() ?? 0
            guard best > 0.3 else { continue }
            list.append(.init(id: app.id, kind: .app, title: app.name, subtitle: appSubtitle(app.url),
                              icon: .file(app.url), action: .open(app.url),
                              score: best + 0.04 + UsageStore.boost(for: app.id, query: q)))
        }
        for place in QuickOpen.places {
            let best = ([place.name] + place.aliases).map { FuzzyMatch.score(q, in: $0) }.max() ?? 0
            guard best > 0.5 else { continue }
            list.append(.init(id: "place:" + place.url.path, kind: .place, title: place.name, subtitle: abbreviate(place.url),
                              icon: .file(place.url), action: .open(place.url),
                              score: best - 0.04 + UsageStore.boost(for: "place:" + place.url.path, query: q)))
        }
        for pane in QuickOpen.settingsPanes {
            let nameScore = FuzzyMatch.score(q, in: pane.name)
            let keywordScore = q.count >= 3 && pane.keywords.contains(q) ? 0.6 : 0
            let best = max(nameScore, keywordScore)
            guard best > 0.5 else { continue }
            list.append(.init(id: "pane:" + pane.id, kind: .setting, title: pane.name, subtitle: "System Settings",
                              icon: .symbol("gearshape.fill", .gray), action: .open(pane.url),
                              score: best - 0.08 + UsageStore.boost(for: "pane:" + pane.id, query: q)))
        }
        for command in QuickOpen.systemCommands {
            let best = max(FuzzyMatch.score(q, in: command.name), q.count >= 3 && command.keywords.contains(q) ? 0.62 : 0)
            guard best > 0.55 else { continue }
            list.append(.init(id: command.id, kind: .system, title: command.name, subtitle: "System",
                              icon: .symbol(command.icon, .gray), action: .system(id: command.id),
                              score: best - 0.06 + UsageStore.boost(for: command.id, query: q)))
        }
        for command in QuickActions.shared.commands {
            let best = max(FuzzyMatch.score(q, in: command.title),
                           q.count >= 4 && command.detail.lowercased().contains(q) ? 0.58 : 0)
            guard best > 0.55 else { continue }
            list.append(commandResult(command, score: best - 0.03 + UsageStore.boost(for: "cmd:" + command.id, query: q)))
        }
        for name in shortcuts {
            let best = FuzzyMatch.score(q, in: name)
            guard best > 0.6 else { continue }
            list.append(.init(id: "shortcut:" + name, kind: .shortcut, title: name, subtitle: "Run Shortcut",
                              icon: .symbol("square.stack.3d.up.fill", .pink), action: .shortcut(name),
                              score: best - 0.08 + UsageStore.boost(for: "shortcut:" + name, query: q)))
        }
        // Past conversations with Space, by title.
        for session in AgentManager.shared.sessions.prefix(300) where !session.title.hasPrefix("New session") && !session.title.isEmpty {
            let best = max(FuzzyMatch.score(q, in: session.title),
                           q.count >= 4 && session.title.lowercased().contains(q) ? 0.6 : 0)
            guard best > 0.55 else { continue }
            list.append(.init(id: "conv:" + session.id, kind: .conversation, title: session.title,
                              subtitle: "Conversation · " + session.updated.formatted(.relative(presentation: .named)),
                              icon: .symbol("bubble.left.and.text.bubble.right.fill", .purple), action: .conversation(id: session.id),
                              score: best - 0.12))
        }
        for (index, hit) in fileHits.enumerated() {
            let nameScore = FuzzyMatch.score(q, in: hit.url.deletingPathExtension().lastPathComponent)
            let recency = hit.lastUsed.map { max(0, 0.06 * (1 - Date().timeIntervalSince($0) / (30 * 86_400))) } ?? 0
            list.append(.init(id: hit.id, kind: hit.isFolder ? .folder : .document, title: hit.name,
                              subtitle: abbreviate(hit.url.deletingLastPathComponent()), icon: .file(hit.url), action: .open(hit.url),
                              score: 0.3 + 0.4 * nameScore + recency - Double(index) * 0.004 + UsageStore.boost(for: hit.id, query: q)))
        }

        // Commands with their details filled in ("Set volume to 50%", the actual song), in place
        // of the generic "type the details" rows for the same command.
        var commandIDs = CommandPreview.detect(query)
        if let picked = snapAnswer?.query == query ? snapAnswer?.command : nil { commandIDs.insert(picked) }
        let resolved = CommandPreview.rows(for: commandIDs.subtracting(["play_music"]), typed: query, shortcuts: shortcuts)
        var resolvedIDs = Set(resolved.compactMap { $0.id.split(separator: ":").dropFirst().first.map(String.init) })
        list += resolved
        if let music, music.query == query, !music.rows.isEmpty {
            list += music.rows
            resolvedIDs.insert("play_music")
        }
        list.removeAll { $0.id.hasPrefix("cmd:") && resolvedIDs.contains(String($0.id.dropFirst(4))) }

        // The agent is always one keystroke away (⇥). Sentences and questions put it on top.
        list.append(.init(id: "ask", kind: .ask, title: query,
                          subtitle: asksAboutScreen ? "Ask Space · screen intelligence" : "Ask Space",
                          icon: .mark, action: .ask(query), score: asksAboutScreen ? 1.5 : askScore(query)))
        if Defaults[.searchWebFallback] || answerIntent == "web_search" {
            if let url = QuickOpen.webSearchURL(query) {
                list.append(.init(id: "web", kind: .web, title: "Search the web for “\(query)”", subtitle: "Google · ⌥⏎ from anywhere in the list",
                                  icon: .symbol("magnifyingglass", .blue), action: .open(url), score: 0.2))
            }
        }

        apply(snapAnswer, to: &list)
        list.sort { $0.score > $1.score }
        results = Array(list.prefix(30))
    }

    private var answerIntent: String? { snapAnswer?.query == currentQuery ? snapAnswer?.intent : nil }

    var asksAboutScreen: Bool {
        Defaults[.screenIntelligence] && ContextCapture.shared.choice != .exclude &&
            (ContextCapture.shared.choice == .include || ContextCapture.shared.captured?.needsSystemTwo(for: currentQuery) == true)
    }

    private func commandResult(_ command: QuickActions.Command, score: Double) -> SearchResult {
        .init(id: "cmd:" + command.id, kind: .command, title: command.title,
              subtitle: command.learned ? "Learned · instant" : (command.standalone ? "System One · instant" : "System One · type the details"),
              icon: .symbol(command.icon, command.learned ? .yellow : .accentColor),
              action: .command(id: command.id, standalone: command.standalone), score: score)
    }

    /// Before Snap 1 answers: sentences, questions and imperative phrases lean toward the agent.
    private func askScore(_ query: String) -> Double {
        let words = query.split(separator: " ")
        let lower = query.lowercased()
        if query.hasSuffix("?") { return 0.97 }
        let starters = ["what", "how", "why", "when", "where", "who", "which", "can ", "could", "should", "is ", "are ", "do ",
                        "does", "summarize", "explain", "write", "draft", "find ", "remind", "make", "create", "tell", "show me",
                        "move", "rename", "convert", "send", "schedule", "add ", "turn", "set ", "play ", "check"]
        if words.count >= 3 || (words.count >= 2 && starters.contains(where: lower.hasPrefix)) { return 0.9 }
        return 0.4
    }

    /// "Application" for the usual places; the folder for apps tucked away elsewhere.
    private func appSubtitle(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let usual = ["/Applications", "/System/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
                     "/System/Library/CoreServices"]
        return usual.contains(folder) ? "Application" : "Application · " + (folder as NSString).abbreviatingWithTildeInPath
    }

    private func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Music

    private func scheduleMusic(for query: String) {
        if music?.query == query || musicTask != nil && pendingMusicQuery == query { return }
        musicTask?.cancel()
        pendingMusicQuery = query
        musicTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))  // wait for a pause in typing
            guard !Task.isCancelled else { return }
            let rows = await CommandPreview.music(for: query)
            guard !Task.isCancelled, let self, self.currentQuery == query else { return }
            self.music = (query, rows)
            self.musicTask = nil
            self.pendingMusicQuery = nil
            withAnimation(.smooth(duration: 0.18)) { self.rebuild() }
        }
    }

    private var pendingMusicQuery: String?

    // MARK: Snap 1

    static func hasLocalAnswer(_ query: String) -> Bool {
        UnitConverter.evaluate(query) != nil || UnitConverter.numberBase(query) != nil || Calculator.evaluate(query) != nil
    }

    private func scheduleSnap(for query: String) {
        snapTask?.cancel()
        guard !Self.hasLocalAnswer(query), !asksAboutScreen, Defaults[.searchSnapRanking], DecisionEngine.shared.onDeviceAvailable, query.count >= 2 else { return }
        snapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            await self.askSnap(query)
        }
    }

    private static let intents: [(String, String)] = [
        ("open_app", "Open or switch to an application"),
        ("open_document", "Open a specific document, file or folder"),
        ("quick_open", "Open a website, a System Settings page or a place like Downloads"),
        ("command", "Run a quick command such as volume, media, dark mode, timer or a learned action"),
        ("calculate", "Calculate something"),
        ("web_search", "Look something up on the web: facts, news, weather, products, people, places, how-tos"),
        ("ask", "A question, a task with several steps, or a request in the user's own words for the assistant"),
    ]

    private func askSnap(_ query: String) async {
        let candidates = results.filter { $0.kind != .ask && $0.kind != .web && $0.kind != .calculation }.prefix(14)
        var options = candidates.enumerated().map { index, result in
            ("r\(index)", "\(result.kind.label): \(result.title)" + (result.kind == .document ? " (in \(result.subtitle))" : ""))
        }
        options.append(("none", "None of these"))
        let commands = QuickActions.shared.commands.prefix(60)
        var commandOptions = commands.map { ($0.id, $0.learned ? "Learned: \($0.title)" : $0.detail) }
        commandOptions.append(("none", "Not a command"))

        let started = Date()
        guard let result = await DecisionEngine.shared.decideOnDevice(
            state: ["typed": query, "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"],
            questions: [
                ("intent", .choice("What is the user trying to do with what they typed into the launcher?", Self.intents)),
                ("pick", .choice("Which result is the user looking for?", options)),
                ("command", .choice("Which quick command, if any, does the text ask for?", commandOptions)),
            ]
        ), !Task.isCancelled, currentQuery == query else { return }

        let pickID = result["pick"]?.choice
        let pick: String? = (result["pick"]?.confidence ?? 0) >= 0.4 && pickID != "none"
            ? pickID.flatMap { Int($0.dropFirst()) }.flatMap { candidates.indices.contains($0) ? candidates[$0].id : nil }
            : nil
        let intent = (result["intent"]?.confidence ?? 0) >= 0.45 ? result["intent"]?.choice : nil
        let command = (result["command"]?.confidence ?? 0) >= 0.6 && result["command"]?.choice != "none" ? result["command"]?.choice : nil
        snapAnswer = (query, pick, intent, command)
        self.intent = intent
        snapLatency = Date().timeIntervalSince(started)
        if pick != nil || command != nil || intent != nil { SpaceMarkEvents.fire(.decided) }
        log.debug("snap: intent=\(intent ?? "-", privacy: .public) pick=\(pick != nil) command=\(command ?? "-", privacy: .public) \(Int((self.snapLatency ?? 0) * 1000))ms")
        withAnimation(.smooth(duration: 0.18)) { rebuild() }
    }

    private func apply(_ answer: (query: String, pick: String?, intent: String?, command: String?)?, to list: inout [SearchResult]) {
        guard let answer, answer.query == currentQuery else { return }
        let resolvedPrefix = answer.command == "play_music" ? "do:music:" : "do:\(answer.command ?? ""):"
        if let commandID = answer.command, !list.contains(where: { $0.id.hasPrefix(resolvedPrefix) }) {
            if commandID == "play_music", music?.query != currentQuery { scheduleMusic(for: currentQuery) }
            if let index = list.firstIndex(where: { $0.id == "cmd:" + commandID }) {
                list[index].score += 0.35
                list[index].snapPick = true
            } else if let command = QuickActions.shared.commands.first(where: { $0.id == commandID }) {
                var row = commandResult(command, score: answer.intent == "command" ? 1.0 : 0.75)
                row.snapPick = true
                list.append(row)
            }
        }
        if let pick = answer.pick, let index = list.firstIndex(where: { $0.id == pick }) {
            list[index].score += answer.intent == "ask" ? 0.1 : 0.3
            list[index].snapPick = list[index].snapPick || answer.intent != "ask"
        }
        if let ask = list.firstIndex(where: { $0.kind == .ask }) {
            switch answer.intent {
            case "ask": list[ask].score = max(list[ask].score, 1.15); list[ask].snapPick = true
            case "open_app", "open_document", "quick_open", "calculate", "web_search": list[ask].score = min(list[ask].score, 0.45)
            case "command" where answer.command == nil: list[ask].score = max(list[ask].score, 0.95)  // routed by System One on send
            default: break
            }
        }
        if answer.intent == "web_search", let web = list.firstIndex(where: { $0.kind == .web }) {
            list[web].score = max(list[web].score, 1.0)
            list[web].snapPick = true
        }
        // Boost the kind Snap 1 expects.
        let kinds: [String: Set<SearchResult.Kind>] = [
            "open_app": [.app], "open_document": [.document, .folder], "quick_open": [.address, .setting, .place, .folder],
            "command": [.command, .system, .shortcut],
        ]
        if let intent = answer.intent, let boosted = kinds[intent] {
            for index in list.indices where boosted.contains(list[index].kind) { list[index].score += 0.08 }
        }
    }
}
