//
//  FuzzyMatch.swift
//  Command Space
//
//  Scores how well a query matches a name, Spotlight/Alfred style:
//  exact > prefix > word prefix > initials ("vsc" → Visual Studio Code) > in-order letters.
//

import Foundation

enum FuzzyMatch {
    /// 0 (no match) … 1 (exact). `query` must already be lowercased and trimmed.
    static func score(_ query: String, in name: String) -> Double {
        guard !query.isEmpty else { return 0 }
        let target = name.lowercased()
        if target == query { return 1 }
        if target.hasPrefix(query) { return 0.92 + 0.06 * Double(query.count) / Double(max(target.count, 1)) }

        let words = splitWords(name)
        // A later word starts with the query: "code" → "Visual Studio Code".
        if words.dropFirst().contains(where: { $0.hasPrefix(query) }) {
            return 0.82 + 0.05 * Double(query.count) / Double(max(target.count, 1))
        }
        // Initials: "vsc", or initials then a prefix of the last word ("vscode").
        let initials = String(words.compactMap(\.first))
        if query.count >= 2, initials.hasPrefix(query) { return 0.8 }
        if query.count >= 2, matchesInitialsThenPrefix(query, words) { return 0.74 }
        if target.contains(query) { return 0.68 }

        // In-order letters, rewarding consecutive runs and word starts.
        var score = 0.0
        var qi = query.startIndex
        var previousMatched = false
        var atWordStart = true
        for ch in target {
            guard qi < query.endIndex else { break }
            if ch == query[qi] {
                score += previousMatched ? 1.5 : (atWordStart ? 1.2 : 0.6)
                previousMatched = true
                qi = query.index(after: qi)
            } else {
                previousMatched = false
            }
            atWordStart = !(ch.isLetter || ch.isNumber)
        }
        guard qi == query.endIndex, query.count >= 2 else { return 0 }
        let maxScore = 1.5 * Double(query.count)
        return 0.25 + 0.35 * min(1, score / maxScore) * min(1, Double(query.count) / Double(target.count) * 2.5)
    }

    /// Lowercased words, splitting on spaces/punctuation and camel case ("PhpStorm" → php, storm).
    static func splitWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousLower = false
        for ch in name {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousLower = false
                continue
            }
            if ch.isUppercase && previousLower && !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(Character(ch.lowercased()))
            previousLower = ch.isLowercase
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func matchesInitialsThenPrefix(_ query: String, _ words: [String]) -> Bool {
        guard words.count >= 2 else { return false }
        for split in 1..<words.count {
            let initials = String(words.prefix(split).compactMap(\.first))
            guard query.hasPrefix(initials) else { continue }
            let rest = String(query.dropFirst(initials.count))
            if !rest.isEmpty, words[split].hasPrefix(rest) { return true }
        }
        return false
    }
}
