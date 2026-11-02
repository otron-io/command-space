//
//  RequestParsing.swift
//  Command Space
//
//  Pure text parsing for instant actions. Jev decides *what* a request is; exact values
//  (numbers, times, names) are read here in code. Foundation-only so it can be unit
//  tested with `swift test` from the repo root.
//

import Foundation

enum RequestParsing {

    // MARK: Levels

    /// A 0–100 number stated in the request ("75", "75%", "volume 33"), if any.
    static func statedPercent(in text: String) -> Float? {
        guard let match = text.range(of: #"\b(\d{1,3})(\.\d+)?\s*(%|percent)?"#, options: .regularExpression) else { return nil }
        let digits = text[match].prefix { $0.isNumber || $0 == "." }
        guard let value = Float(digits), (0...100).contains(value) else { return nil }
        return value
    }

    /// A level stated as a number or in words ("max", "half", "off"), as 0–100.
    static func statedLevel(in text: String) -> Float? {
        if let number = statedPercent(in: text) { return number }
        let lower = text.lowercased()
        let words: [(String, Float)] = [
            (#"\b(max|maximum|full|all the way up|loudest|brightest)\b"#, 100),
            (#"\b(three quarters)\b"#, 75),
            (#"\b(half|halfway|medium|middle)\b"#, 50),
            (#"\b(a quarter|quarter|low|quiet)\b"#, 25),
            (#"\b(off|zero|silent|min|minimum|lowest)\b"#, 0),
        ]
        return words.first { lower.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    // MARK: Music

    /// "Play Bohemian Rhapsody by Queen on Spotify" → ("Bohemian Rhapsody", "Queen").
    static func musicQuery(from text: String) -> (query: String, artist: String?) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(hey\s+)?((notch|space)[,\s]+)?(please\s+)?(can you\s+|could you\s+)?(play|put on|queue up|queue|start|listen to|shuffle|throw on)\s+"#,
            #"^(me\s+)?(some\s+)?(the\s+)?(my\s+)?(song|track|album|playlist|artist)\s+"#,
            #"^(my|the)\s+"#,
            #"^(some|a little|a bit of|a few)\s+"#,
            #"[.!?]+$"#,
            #"\s+(on|in|from|with|using)\s+spotify$"#,
            #"\s+(playlist|album|song|track)$"#,
            #",?\s*please$"#,
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }
        if let range = s.range(of: #"\s+by\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let title = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let artist = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, !artist.isEmpty { return (title, artist) }
        }
        return (s, nil)
    }

    // MARK: Menu commands

    /// Orders menu paths ("View › Zoom In") by word overlap with the request, keeping the
    /// menu order for ties, and returns at most `limit` (Jev allows 255 options per question).
    static func rankMenuItems(_ items: [String], for request: String, limit: Int = 240) -> [String] {
        guard items.count > limit else { return items }
        let words = Set(request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        func score(_ item: String) -> Int {
            let itemWords = item.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var total = 0
            for word in words {
                for candidate in itemWords where candidate.hasPrefix(String(word.prefix(4))) || word.hasPrefix(String(candidate.prefix(4))) {
                    total += candidate == word ? 3 : 1
                }
            }
            return total
        }
        return items.enumerated()
            .map { (index: $0.offset, item: $0.element, score: score($0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map(\.item)
    }

    /// Whether a request points at something on screen ("summarize this", "these files").
    static func mentionsOnScreen(_ text: String) -> Bool {
        text.range(of: #"\b(this|these|that|those|here|selected|selection|highlighted|window|screen|looking at|(?:the|current|active) (?:page|tab|site|article|website|email|file|files|image|photo|document))\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Learned actions

    /// Commands that are never learned: anything destructive, privileged or networked-to-shell.
    static let unsafeCommandPatterns = [
        #"\brm\b"#, #"\bsudo\b"#, #"\bmv\b.*\s/dev/null"#, #"\bdd\b"#, #"\bmkfs"#, #"\bdiskutil\s+(erase|partition)"#,
        #"\bkill(all)?\b"#, #"\bshutdown\b"#, #"\breboot\b"#, #"\bhalt\b"#, #"\blaunchctl\s+(unload|bootout|remove)"#,
        #"\|\s*(ba|z)?sh\b"#, #"curl[^|]*\|\s*"#, #"(?<![0-9&])>(?!\s*/dev/null|&)"#, #"\bchmod\b"#, #"\bchown\b"#, #"\bgit\s+(push|reset|clean)"#,
        #"\bdefaults\s+delete"#, #"\bsecurity\s+delete"#, #"\bosascript\b.*\b(delete|empty trash)\b"#,
    ]

    static func isSafeToLearn(_ command: String) -> Bool {
        !unsafeCommandPatterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // MARK: Durations (timers)

    /// Total seconds for "10 minutes", "1 hour 30 minutes", "90 seconds", "half an hour",
    /// "an hour and a half", "5 min". Nil when no duration is stated.
    static func duration(in text: String) -> TimeInterval? {
        let lower = text.lowercased()
        var total: TimeInterval = 0
        var found = false

        let unitSeconds: [(String, TimeInterval)] = [
            (#"h(ou)?rs?"#, 3600), (#"m(in(ute)?s?)?"#, 60), (#"s(ec(ond)?s?)?"#, 1),
        ]
        for (unit, seconds) in unitSeconds {
            let pattern = #"(\d+(?:\.\d+)?)\s*"# + unit + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                if let range = Range(match.range(at: 1), in: lower), let value = Double(lower[range]) {
                    total += value * seconds
                    found = true
                }
            }
        }
        let phrases: [(String, TimeInterval)] = [
            ("an hour and a half", 5400), ("hour and a half", 5400), ("half an hour", 1800),
            ("quarter of an hour", 900), ("quarter hour", 900), ("a minute", 60), ("an hour", 3600),
        ]
        if !found {
            for (phrase, seconds) in phrases where lower.contains(phrase) {
                total = seconds
                found = true
                break
            }
        } else if lower.contains("and a half") {
            // "1 hour and a half" → add half of the largest unit mentioned.
            total += lower.contains("hour") ? 1800 : 30
        }
        return found && total > 0 ? total : nil
    }

    // MARK: Dates (reminders, events)

    struct DatedText: Equatable {
        /// The request with the date/time phrase and command words removed.
        var title: String
        var date: Date?
        /// Seconds, when a range like "2 to 3pm" was given.
        var duration: TimeInterval?
        var hasTime: Bool
    }

    /// Finds the date/time in a request with NSDataDetector and returns the remaining text
    /// as a title. `commandPatterns` are stripped from the start (e.g. "remind me to").
    static func datedText(_ text: String, commandPatterns: [String], now: Date = Date()) -> DatedText {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var date: Date?
        var duration: TimeInterval?
        var hasTime = false

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let range = Range(match.range, in: working) {
            date = match.date
            duration = match.duration > 0 ? match.duration : nil
            let phrase = working[range].lowercased()
            hasTime = phrase.range(of: #"\d\s*(:\d\d)?\s*(am|pm|a\.m\.|p\.m\.)|\d:\d\d|noon|midnight|morning|afternoon|evening|tonight|o'?clock|\bat\s+\d"#,
                                   options: .regularExpression) != nil
            working.removeSubrange(range)
            // NSDataDetector defaults "tomorrow"/"monday" to 9:00 or 12:00; keep only the day.
            if !hasTime, let found = date {
                date = Calendar.current.startOfDay(for: found)
            }
            // A bare past time today ("at 9" at 10pm) means tomorrow.
            if hasTime, let found = date, found < now, Calendar.current.isDate(found, inSameDayAs: now) {
                date = Calendar.current.date(byAdding: .day, value: 1, to: found)
            }
        }

        // A bare hour the detector skips: "at 6", "at 6:30", alone or after a day ("tomorrow at 6").
        if !hasTime, let match = working.range(of: #"\bat\s+(\d{1,2})(:(\d{2}))?\b(?!\s*(%|percent|min|minutes|hours|hrs|h\b))"#,
                                              options: [.regularExpression, .caseInsensitive]) {
            let digits = working[match].dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: ":")
            if let hour = Int(digits[0]), (1...12).contains(hour) || (13...23).contains(hour) {
                let minute = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
                date = bareHour(hour, minute: minute, on: date, now: now)
                hasTime = date != nil
                if hasTime { working.removeSubrange(match) }
            }
        }

        for pattern in commandPatterns + [#"^(hey\s+)?((notch|space)[,\s]+)?(please\s+)?(can you\s+|could you\s+)?"#] {
            working = working.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }
        // Tidy leftovers like trailing "at", "on", "for", punctuation.
        for pattern in [#"\s+(at|on|for|by|from|to|in)\s*$"#, #"^(at|on|for|to)\s+"#, #"[.,!?]+$"#, #"\s{2,}"#] {
            working = working.replacingOccurrences(of: pattern, with: pattern == #"\s{2,}"# ? " " : "",
                                                   options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }
        if let first = working.first { working = first.uppercased() + working.dropFirst() }
        return DatedText(title: working, date: date, duration: duration, hasTime: hasTime)
    }

    /// The next sensible moment for a bare hour: "6" is 6 pm unless 6 am is still ahead today
    /// and plausible; hours before 7 are always afternoon/evening. On a given day, the same rule.
    static func bareHour(_ hour: Int, minute: Int, on day: Date?, now: Date) -> Date? {
        let calendar = Calendar.current
        func at(_ h: Int, _ base: Date) -> Date? { calendar.date(bySettingHour: h, minute: minute, second: 0, of: base) }
        if hour > 12 { return at(hour, day ?? now).map { $0 < now && day == nil ? calendar.date(byAdding: .day, value: 1, to: $0)! : $0 } }
        let candidates = hour < 7 ? [hour + 12] : (hour == 12 ? [12] : [hour, hour + 12])
        if let day, !calendar.isDate(day, inSameDayAs: now) { return at(candidates[0], day) }
        if let next = candidates.compactMap({ at($0, now) }).first(where: { $0 > now }) { return next }
        return calendar.date(byAdding: .day, value: 1, to: now).flatMap { at(candidates[0], $0) }
    }

    static let reminderCommands = [
        #"^(set\s+(a\s+)?)?reminder\s+(to\s+|for\s+|that\s+)?"#,
        #"^remind\s+me\s+(to\s+|about\s+|that\s+)?"#,
        #"^(add|create|make)\s+(a\s+)?(reminder|todo|to-do|task)\s+(to\s+|for\s+)?"#,
        #"^don'?t\s+let\s+me\s+forget\s+(to\s+)?"#,
    ]

    static let eventCommands = [
        #"^(add|create|make|schedule|put|book|block)\s+(an?\s+)?(event|meeting|appointment|time|slot)?\s*(for\s+|called\s+|to\s+)?"#,
        #"^(block\s+(off|out)\s+)"#,
        #"\s+(on|to|in)\s+(my\s+)?calendar"#,
    ]

    /// "set a timer for 10 minutes for pasta" → "pasta".
    static func timerLabel(from text: String) -> String? {
        var s = text.lowercased()
        for pattern in [#"(set\s+)?(a\s+)?timer"#, #"(for\s+)?\d+(\.\d+)?\s*(h(ou)?rs?|m(in(ute)?s?)?|s(ec(ond)?s?)?)\b"#,
                        #"(for\s+)?(an hour and a half|half an hour|an hour|a minute|quarter of an hour)"#,
                        #"\band\b"#, #"^(hey\s+)?((notch|space)[,\s]+)?(please\s+)?"#, #"[.,!?]"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"^\s*(for|called|named|to)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s.prefix(1).uppercased() + s.dropFirst()
    }
}
