//
//  UsageStore.swift
//  Command Space
//
//  Learns what you pick: how often and how recently each result was opened, and which
//  result you chose for a given query ("s" → Slack, not Safari). Stored on this Mac only.
//

import Defaults
import Foundation

extension Defaults.Keys {
    static let usageCounts = Key<[String: Int]>("usageCounts", default: [:])
    static let usageLastUsed = Key<[String: Double]>("usageLastUsed", default: [:])
    /// query prefix → result id → times chosen
    static let usageQueryPicks = Key<[String: [String: Int]]>("usageQueryPicks", default: [:])
}

@MainActor
enum UsageStore {
    /// 0…0.25 bonus for a result, given what's been picked before.
    static func boost(for id: String, query: String) -> Double {
        let counts = Defaults[.usageCounts]
        let lastUsed = Defaults[.usageLastUsed]
        var bonus = 0.0
        if let count = counts[id] { bonus += min(0.08, log2(Double(count) + 1) * 0.02) }
        if let last = lastUsed[id] {
            let days = (Date().timeIntervalSince1970 - last) / 86_400
            bonus += max(0, 0.05 * (1 - days / 14))
        }
        if !query.isEmpty, let picks = Defaults[.usageQueryPicks][key(query)], let picked = picks[id] {
            let total = picks.values.reduce(0, +)
            bonus += 0.12 * Double(picked) / Double(max(total, 1))
        }
        return bonus
    }

    static func recordPick(_ id: String, query: String) {
        Defaults[.usageCounts][id, default: 0] += 1
        Defaults[.usageLastUsed][id] = Date().timeIntervalSince1970
        guard !query.isEmpty else { return }
        var all = Defaults[.usageQueryPicks]
        // Remember the pick for each prefix typed (up to 4 characters), so "s", "sl" and "sla" all learn.
        let lowered = query.lowercased()
        for length in 1...min(4, lowered.count) {
            let prefix = key(String(lowered.prefix(length)))
            all[prefix, default: [:]][id, default: 0] += 1
        }
        if all.count > 2000 { all = all.filter { $0.value.values.reduce(0, +) > 1 } }
        Defaults[.usageQueryPicks] = all
    }

    /// Most used ids, most recent first among equals.
    static func recent(limit: Int) -> [String] {
        let lastUsed = Defaults[.usageLastUsed]
        return lastUsed.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private static func key(_ query: String) -> String {
        String(query.lowercased().trimmingCharacters(in: .whitespaces).prefix(4))
    }
}
