//
//  CommandPreview.swift
//  Command Space
//
//  Turns a System One command plus what you typed into the exact thing that will happen:
//  "volume 50" → "Set volume to 50%", "remind me to call mom at 6" → the reminder with its
//  time, "play cruel summer" → the actual songs, albums and playlists on Spotify. ⏎ then runs
//  exactly what the row shows.
//

import AppKit
import Foundation
/// A fully specified command, ready to run without asking anything else.
enum ResolvedCommand: Equatable {
    case volume(Float)                       // 0…1
    case brightness(Float)                   // 0…1
    case timer(TimeInterval, label: String?)
    case reminder(request: String)
    case event(request: String)
    case shortcut(String)
    case spotify(uri: String, label: String)
    case spotifySearch(String)               // not logged in: open Spotify's search
}

@MainActor
enum CommandPreview {
    // MARK: Which command the text asks for

    /// Commands recognisable from the wording alone (before Snap 1 answers).
    static func detect(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        var ids: Set<String> = []
        if has(#"^(hey\s+)?(please\s+)?(play|listen to|put on|queue( up)?|shuffle|throw on)\s+\S"#) { ids.insert("play_music") }
        if has(#"\b(volume|sound)\b"#), RequestParsing.statedLevel(in: lower) != nil { ids.insert("set_volume") }
        if has(#"\bbrightness\b|\bscreen (to|at)\b"#), RequestParsing.statedLevel(in: lower) != nil { ids.insert("set_brightness") }
        if has(#"\b(timer|countdown)\b"#) || has(#"^(set\s+)?(a\s+)?\d+\s*(s|sec|secs|seconds|m|min|mins|minutes|h|hr|hrs|hours)\b"#),
           RequestParsing.duration(in: lower) != nil { ids.insert("set_timer") }
        if has(#"^(remind me|reminder|add a reminder|add reminder)\b"#) { ids.insert("add_reminder") }
        if has(#"^(add|block|schedule|create|put)\b.*\b(event|meeting|calendar|for)\b"#) || has(#"^block\s"#) { ids.insert("add_event") }
        if has(#"^(run|start|trigger)\s+\S"#) { ids.insert("run_shortcut") }
        return ids
    }

    // MARK: Rows for everything except music

    static func rows(for ids: Set<String>, typed: String, shortcuts: [String]) -> [SearchResult] {
        var rows: [SearchResult] = []
        for id in ids {
            switch id {
            case "set_volume":
                guard let level = RequestParsing.statedLevel(in: typed) else { continue }
                rows.append(row(id, "Set volume to \(Int(level))%", "System One · instant",
                                level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", .volume(level / 100)))
            case "set_brightness":
                guard let level = RequestParsing.statedLevel(in: typed) else { continue }
                rows.append(row(id, "Set brightness to \(Int(level))%", "System One · instant", "sun.max.fill", .brightness(level / 100)))
            case "set_timer":
                guard let seconds = RequestParsing.duration(in: typed) else { continue }
                let label = RequestParsing.timerLabel(from: typed)
                let title = label.map { "Start a \(AgentTimers.format(seconds)) \($0) timer" } ?? "Start a \(AgentTimers.format(seconds)) timer"
                let ends = Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
                rows.append(row(id, title, "System One · ends at \(ends)", "timer", .timer(seconds, label: label)))
            case "add_reminder":
                let parsed = RequestParsing.datedText(typed, commandPatterns: RequestParsing.reminderCommands)
                guard !parsed.title.isEmpty else { continue }
                let when = parsed.date.map { InstantPlanning.describe($0, withTime: parsed.hasTime) } ?? "no due date"
                rows.append(row(id, "Remind me: \(parsed.title)", "Reminders · \(when)", "checklist", .reminder(request: typed)))
            case "add_event":
                let parsed = RequestParsing.datedText(typed, commandPatterns: RequestParsing.eventCommands)
                guard let start = parsed.date, !parsed.title.isEmpty else { continue }
                var when = InstantPlanning.describe(start, withTime: parsed.hasTime)
                if parsed.hasTime {
                    when += "–" + start.addingTimeInterval(parsed.duration ?? 3600).formatted(date: .omitted, time: .shortened)
                }
                rows.append(row(id, "Add “\(parsed.title)”", "Calendar · \(when)", "calendar.badge.plus", .event(request: typed)))
            case "run_shortcut":
                let name = typed.lowercased()
                    .replacingOccurrences(of: #"^(run|start|trigger)\s+(my\s+|the\s+)?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+shortcut$"#, with: "", options: .regularExpression)
                let matches = shortcuts.map { ($0, FuzzyMatch.score(name, in: $0)) }.filter { $0.1 > 0.6 }.sorted { $0.1 > $1.1 }
                for (index, match) in matches.prefix(2).enumerated() {
                    rows.append(row(id, "Run “\(match.0)”", "Shortcut", "square.stack.3d.up.fill", .shortcut(match.0),
                                    tint: .systemPink, score: 1.06 - Double(index) * 0.02, key: match.0))
                }
            default:
                continue
            }
        }
        return rows
    }

    private static func row(_ id: String, _ title: String, _ subtitle: String, _ icon: String, _ command: ResolvedCommand,
                            tint: NSColor = .controlAccentColor, score: Double = 1.08, key: String = "") -> SearchResult {
        SearchResult(id: "do:\(id):\(key)", kind: .command, title: title, subtitle: subtitle,
                     icon: .symbol(icon, Color(nsColor: tint)), action: .resolved(command), score: score)
    }

    // MARK: Music

    /// Real Spotify results for "play …": the songs, the album, the artist, your playlists.
    static func music(for typed: String) async -> [SearchResult] {
        let (query, artist) = RequestParsing.musicQuery(from: typed)
        let spotify = SpotifyClient.shared
        let lower = typed.lowercased()
        guard !query.isEmpty else { return [] }

        guard spotify.isConnected else {
            return [SearchResult(id: "do:music:search", kind: .command, title: "Search Spotify for “\(query)”",
                                 subtitle: "Connect Spotify in Settings to play it directly",
                                 icon: .symbol("magnifyingglass", .green), action: .resolved(.spotifySearch(query)), score: 1.08)]
        }
        if lower.contains("liked songs") || lower.contains("my likes"), let uri = spotify.likedSongsURI {
            return [musicRow(SpotifyItem(uri: uri, name: "Liked Songs", subtitle: "Your library"), score: 1.12)]
        }

        // "play something by Daft Punk", "play some music by X": the artist, not a song called "something".
        let vague = query.lowercased().range(of: #"^(some(thing)?|anything|music|songs?|tunes|stuff|a song|some songs|some music)$"#,
                                              options: .regularExpression) != nil
        if vague, let artist {
            let found = await spotify.search(artist, kind: "artist", limit: 1)
            async let topTracks = spotify.search("artist:\(artist)", kind: "track", limit: 3)
            var rows = found.prefix(1).map { musicRow($0, score: 1.14) }
            rows += await topTracks.enumerated().map { musicRow($0.element, score: 1.05 - Double($0.offset) * 0.02) }
            return rows
        }

        let trackQuery = artist.map { "track:\(query) artist:\($0)" } ?? query
        async let tracks = spotify.search(trackQuery, kind: "track", limit: 4)
        async let albums = spotify.search(artist.map { "album:\(query) artist:\($0)" } ?? query, kind: "album", limit: 2)
        async let artists = spotify.search(artist ?? query, kind: "artist", limit: 1)
        async let playlists = spotify.myPlaylists()
        let wantsPlaylist = lower.contains("playlist") || lower.contains(" my ")
        let playlistQuery = query.lowercased().replacingOccurrences(of: #"^my\s+|\s*playlist$"#, with: "", options: .regularExpression)
        async let publicPlaylists = wantsPlaylist ? spotify.search(playlistQuery, kind: "playlist", limit: 3) : []
        let (rawTracks, rawAlbums, rawArtists, mine, rawPlaylists) = await (tracks, albums, artists, playlists, publicPlaylists)

        // Spotify returns loose matches; keep results that share words with what was typed.
        // Only the words that say *what* to play count ("play", "my", "playlist" don't).
        let filler: Set<String> = ["play", "my", "the", "a", "an", "some", "by", "on", "spotify", "playlist", "song", "songs",
                                   "album", "music", "please", "put", "listen", "to", "me", "queue", "up", "shuffle"]
        let typedWords = Set(FuzzyMatch.splitWords(typed).filter { $0.count > 1 && !filler.contains($0) })
        func overlap(_ item: SpotifyItem) -> Double {
            guard !typedWords.isEmpty else { return 1 }
            let words = Set(FuzzyMatch.splitWords(item.name + " " + item.subtitle))
            return Double(typedWords.filter(words.contains).count) / Double(typedWords.count)
        }
        func relevant(_ items: [SpotifyItem]) -> [SpotifyItem] {
            // Stable: Spotify's own order breaks ties.
            struct Scored { let item: SpotifyItem; let score: Double; let rank: Int }
            let scored: [Scored] = items.enumerated().map { Scored(item: $0.element, score: overlap($0.element), rank: $0.offset) }
            let kept = scored.filter { $0.score >= 0.5 }
            let sorted = kept.sorted { a, b in a.score != b.score ? a.score > b.score : a.rank < b.rank }
            return sorted.map(\.item)
        }
        let t = relevant(rawTracks)
        let al = relevant(rawAlbums)
        // Only an artist whose whole name was typed.
        let ar = rawArtists.filter { artist in
            let words = FuzzyMatch.splitWords(artist.name)
            return !words.isEmpty && words.allSatisfy(typedWords.contains)
        }

        // Your own playlists first when the name matches ("play my gym playlist").
        let q = query.lowercased().replacingOccurrences(of: #"^my\s+|\s+playlist$"#, with: "", options: .regularExpression)
        let ownMatches = mine.map { ($0, FuzzyMatch.score(q, in: $0.name)) }.filter { $0.1 > 0.7 }.sorted { $0.1 > $1.1 }.prefix(2)

        var rows: [SearchResult] = []
        for (index, match) in ownMatches.enumerated() {
            rows.append(musicRow(match.0, score: (wantsPlaylist ? 1.14 : 1.0) - Double(index) * 0.01, mine: true))
        }
        // Whatever the wording asks for leads: "album …", "songs by …", otherwise the song.
        let albumFirst = lower.contains("album")
        let artistFirst = lower.range(of: #"\b(songs by|music by|some)\b"#, options: .regularExpression) != nil
        if wantsPlaylist {
            for (index, item) in relevant(rawPlaylists).prefix(2).enumerated() {
                rows.append(musicRow(item, score: 1.1 - Double(index) * 0.02))
            }
        }
        // Asked for a playlist and found some: songs and albums that merely share a word are noise.
        if wantsPlaylist && !rows.isEmpty { return rows }
        let demote = albumFirst || artistFirst || wantsPlaylist ? 0.14 : 0
        for (index, item) in t.prefix(3).enumerated() {
            rows.append(musicRow(item, score: 1.12 - Double(index) * 0.03 - demote))
        }
        for (index, item) in al.prefix(1 + (albumFirst ? 1 : 0)).enumerated() {
            rows.append(musicRow(item, score: (albumFirst ? 1.13 : 1.0) - Double(index) * 0.02 - (wantsPlaylist ? 0.14 : 0)))
        }
        if let top = ar.first {
            rows.append(musicRow(top, score: artistFirst ? 1.13 : 0.99))
        }
        return rows
    }

    private static func musicRow(_ item: SpotifyItem, score: Double, mine: Bool = false) -> SearchResult {
        let kindLabel: String
        switch item.kind {
        case "album": kindLabel = "Album"
        case "artist": kindLabel = "Artist"
        case "playlist": kindLabel = mine ? "Your playlist" : "Playlist"
        case "user", "collection": kindLabel = "Liked Songs"
        default: kindLabel = "Song"
        }
        let subtitle = item.subtitle.isEmpty ? "\(kindLabel) · Spotify" : "\(kindLabel) · \(item.subtitle)"
        let label = item.subtitle.isEmpty || item.kind == "playlist" ? "Playing \(item.name)" : "Playing \(item.name) — \(item.subtitle)"
        return SearchResult(id: "do:music:\(item.uri)", kind: .command, title: item.name, subtitle: subtitle,
                            icon: item.imageURL.map { .remote($0, rounded: item.kind != "artist") } ?? .symbol("music.note", .green),
                            action: .resolved(.spotify(uri: item.uri, label: label)), score: score)
    }

    // MARK: Running

    /// Runs exactly what the row shows; returns the result for the live pill.
    static func run(_ command: ResolvedCommand) async -> (label: String, icon: String)? {
        switch command {
        case .volume(let level):
            VolumeManager.shared.setAbsolute(level)
            return ("Volume \(Int(level * 100))%", level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        case .brightness(let level):
            BrightnessManager.shared.setAbsolute(value: level)
            return ("Brightness \(Int(level * 100))%", "sun.max.fill")
        case .timer(let seconds, let label):
            return (AgentTimers.shared.start(seconds, label: label), "timer")
        case .reminder(let request):
            return await InstantPlanning.addReminder(from: request).map { ($0, "checklist") }
        case .event(let request):
            return await InstantPlanning.addEvent(from: request).map { ($0, "calendar.badge.plus") }
        case .shortcut(let name):
            let ok = await SystemBridge.shared.runShortcut(name)
            return ok ? ("Ran \(name)", "square.stack.3d.up.fill") : ("Couldn't run \(name)", "exclamationmark.triangle.fill")
        case .spotify(let uri, let label):
            let ok = await SpotifyClient.shared.play(uri: uri)
            return ok ? (label, "music.note") : ("Couldn't play on Spotify", "exclamationmark.triangle.fill")
        case .spotifySearch(let query):
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            if let url = URL(string: "spotify:search:\(encoded)") { NSWorkspace.shared.open(url) }
            return ("Searching Spotify for “\(query)”", "magnifyingglass")
        }
    }
}

import SwiftUI
