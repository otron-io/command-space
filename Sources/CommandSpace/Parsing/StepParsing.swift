//
//  StepParsing.swift
//  Command Space
//
//  Turns "open notes and create a new note and add text saying Hello world" into steps
//  System One can run one at a time. Everything here is plain code: Snap 1 only picks
//  between options, so text to type always comes straight from the user's words.
//

import AppKit
import Foundation

enum StepParsing {
    /// A step that needs no model at all.
    enum LocalStep: Equatable {
        case open(String)
        case type(String)
        case press(KeyChord, times: Int)
        case wait(TimeInterval)
    }

    struct KeyChord: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let label: String
    }

    // MARK: Splitting

    /// Words that start a new step ("… and press enter"). Anything else after "and" belongs to
    /// the previous step ("type salt and pepper").
    static let stepVerbs: Set<String> = [
        "open", "launch", "start", "switch", "go", "close", "create", "make", "add", "new", "type",
        "write", "enter", "insert", "put", "press", "hit", "tap", "click", "select", "choose", "pick",
        "search", "find", "save", "copy", "paste", "cut", "undo", "redo", "scroll", "wait", "show",
        "hide", "toggle", "turn", "set", "pause", "mute", "unmute", "skip", "zoom", "bold", "italicize",
        "underline", "rename", "export", "print", "duplicate", "send", "delete", "remove", "move",
        "sort", "format", "change", "use", "mark", "pin", "attach", "reply", "forward", "take",
        "focus", "minimize", "maximize", "fullscreen", "enable", "disable", "check", "uncheck", "bring", "play",
    ]

    /// Requests that carry their own "and" (a reminder's text, a question) are never split.
    private static let wholeRequestPattern =
        #"^\s*(?:remind|reminder|schedule|book|add (?:an? )?(?:event|meeting|reminder)|set (?:a |an )?(?:timer|alarm|reminder)|what|what's|whats|how|why|who|when|where|which|is|are|can|could|would|should|do|does|did|tell|explain|summari[sz]e|draft|compose|translate|play)\b"#

    /// The request's steps, or the whole request as one step when it isn't a chain.
    static func split(_ request: String) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.range(of: wholeRequestPattern, options: [.regularExpression, .caseInsensitive]) != nil { return [trimmed] }

        // Quoted text is never split.
        var quoted: [String] = []
        let masked = mask(trimmed, into: &quoted)
        let separator = #"\s*(?:,\s*(?:and\s+)?(?:then\s+)?|;\s*|\s+and\s+then\s+|\s+then\s+|\s+and\s+|\s+after that\s+)"#
        guard let regex = try? NSRegularExpression(pattern: separator, options: [.caseInsensitive]) else { return [trimmed] }
        let ns = masked as NSString
        var pieces: [String] = []
        var start = 0
        for match in regex.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: start))

        let separators = regex.matches(in: masked, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var steps: [String] = []
        for (index, piece) in pieces.enumerated() {
            let clean = piece.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            if steps.isEmpty || startsWithStepVerb(clean) {
                steps.append(clean)
            } else {
                // Not a step of its own: "type salt and pepper" stays one step.
                steps[steps.count - 1] += separators[index - 1] + clean
            }
        }
        return steps.map { unmask($0, quoted) }.filter { !$0.isEmpty }
    }

    private static func startsWithStepVerb(_ text: String) -> Bool {
        guard let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first else { return false }
        return stepVerbs.contains(String(first))
    }

    private static func mask(_ text: String, into quoted: inout [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"["“][^"“”]*["”]"#) else { return text }
        let ns = text as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            output += "\u{1}\(quoted.count)\u{1}"
            quoted.append(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return output + ns.substring(from: last)
    }

    private static func unmask(_ text: String, _ quoted: [String]) -> String {
        var output = text
        for (index, value) in quoted.enumerated() {
            output = output.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: value)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    // MARK: Local steps

    static func local(_ step: String) -> LocalStep? {
        let text = step.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed = typedText(in: text) { return .type(typed) }
        if let (chord, times) = keyPress(in: text) { return .press(chord, times: times) }
        if let seconds = waitDuration(in: text) { return .wait(seconds) }
        if let app = appName(in: text) { return .open(app) }
        return nil
    }

    /// "type hello", "add text saying Hello world", "write “dear Sam”", "enter my name is Mo".
    static func typedText(in step: String) -> String? {
        // "type in the search field" picks a field, it doesn't type anything.
        if step.range(of: #"^(?:type|enter|write)\s+in(?:to)?\s+(?:the|a|an)\s+[\w ]{0,30}(?:field|box|bar|area)$"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let patterns = [
            #"^(?:please\s+)?(?:type|enter|insert)\s+(?:out\s+|in\s+)?(?:the\s+)?(?:(?:text|words?|phrase)\s+)?(?:saying\s+|that says\s+|reading\s+)?:?\s*(.+)$"#,
            #"^(?:please\s+)?(?:add|put|write)\s+(?:in\s+)?(?:some\s+|the\s+|a\s+)?(?:text|words?|phrase|line)\s+(?:saying\s+|that says\s+|reading\s+|of\s+)?:?\s*(.+)$"#,
            #"^(?:please\s+)?(?:add|put|write|say)\s+(?:the\s+)?(?:text\s+)?(\u{22}.+\u{22}|“.+”|'.+')$"#,
            #"^(?:please\s+)?write\s+(?:saying\s+|that says\s+)(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: step, range: NSRange(step.startIndex..., in: step)),
                  let range = Range(match.range(at: 1), in: step) else { continue }
            var value = String(step[range]).trimmingCharacters(in: .whitespaces)
            // Strip one pair of surrounding quotes.
            if let first = value.first, let last = value.last, value.count >= 2,
               "\"“'".contains(first), "\"”'".contains(last) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static let keyCodes: [String: (CGKeyCode, String)] = [
        "enter": (36, "⏎"), "return": (36, "⏎"), "tab": (48, "⇥"), "space": (49, "Space"), "spacebar": (49, "Space"),
        "escape": (53, "esc"), "esc": (53, "esc"), "delete": (51, "⌫"), "backspace": (51, "⌫"),
        "forward delete": (117, "⌦"), "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"), "right": (124, "→"),
        "up arrow": (126, "↑"), "down arrow": (125, "↓"), "left arrow": (123, "←"), "right arrow": (124, "→"),
        "home": (115, "↖"), "end": (119, "↘"), "page up": (116, "⇞"), "page down": (121, "⇟"),
        "a": (0, "A"), "b": (11, "B"), "c": (8, "C"), "d": (2, "D"), "e": (14, "E"), "f": (3, "F"), "g": (5, "G"),
        "h": (4, "H"), "i": (34, "I"), "j": (38, "J"), "k": (40, "K"), "l": (37, "L"), "m": (46, "M"), "n": (45, "N"),
        "o": (31, "O"), "p": (35, "P"), "q": (12, "Q"), "r": (15, "R"), "s": (1, "S"), "t": (17, "T"), "u": (32, "U"),
        "v": (9, "V"), "w": (13, "W"), "x": (7, "X"), "y": (16, "Y"), "z": (6, "Z"),
        "0": (29, "0"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"),
        "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        ",": (43, ","), ".": (47, "."), "/": (44, "/"), "comma": (43, ","), "period": (47, "."), "slash": (44, "/"),
    ]

    private static let modifierWords: [String: (CGEventFlags, String)] = [
        "command": (.maskCommand, "⌘"), "cmd": (.maskCommand, "⌘"), "⌘": (.maskCommand, "⌘"),
        "shift": (.maskShift, "⇧"), "⇧": (.maskShift, "⇧"),
        "option": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"), "opt": (.maskAlternate, "⌥"), "⌥": (.maskAlternate, "⌥"),
        "control": (.maskControl, "⌃"), "ctrl": (.maskControl, "⌃"), "⌃": (.maskControl, "⌃"),
    ]

    /// "press enter", "hit command b", "press ⌘⇧N", "press tab twice".
    static func keyPress(in step: String) -> (KeyChord, Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:press|hit|tap)\s+(?:the\s+)?(.+?)(?:\s+key)?(?:\s+(once|twice|three times|thrice|(\d+) times))?$"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: step, range: NSRange(step.startIndex..., in: step)),
              let keysRange = Range(match.range(at: 1), in: step) else { return nil }
        var times = 1
        if let r = Range(match.range(at: 2), in: step) {
            switch step[r].lowercased() {
            case "twice": times = 2
            case "three times", "thrice": times = 3
            default:
                if let n = Range(match.range(at: 3), in: step).flatMap({ Int(step[$0]) }) { times = min(max(n, 1), 20) }
            }
        }
        // Split "command shift n", "cmd+shift+n" and "⌘⇧N" into tokens.
        var spec = step[keysRange].lowercased()
        for symbol in ["⌘", "⇧", "⌥", "⌃"] { spec = spec.replacingOccurrences(of: symbol, with: " \(symbol) ") }
        var tokens = spec.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "-" }).map(String.init).filter { $0 != "and" }
        var flags: CGEventFlags = []
        var label = ""
        while let first = tokens.first, let modifier = modifierWords[first] {
            flags.insert(modifier.0)
            if !label.contains(modifier.1) { label += modifier.1 }
            tokens.removeFirst()
        }
        let keyName = tokens.joined(separator: " ")
        guard let key = keyCodes[keyName] else { return nil }
        // A bare letter is "press b" — fine with modifiers, but alone it's more likely typing.
        if flags.isEmpty, keyName.count == 1, keyName.first?.isLetter == true { return nil }
        return (KeyChord(keyCode: key.0, flags: flags, label: label + key.1), times)
    }

    static func waitDuration(in step: String) -> TimeInterval? {
        guard step.range(of: #"^(?:wait|pause)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        if step.range(of: #"^(?:wait|pause)(?:\s+(?:a\s+)?(?:sec|second|moment|bit))?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        return RequestParsing.duration(in: step).map { min($0, 30) }
    }

    /// "open notes", "launch Safari", "switch to Slack", "go to Mail".
    static func appName(in step: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:please\s+)?(?:open(?:\s+up)?|launch|start|switch\s+to|go\s+to|bring\s+up|focus(?:\s+on)?)\s+(?:the\s+)?(.+?)(?:\s+app)?$"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: step, range: NSRange(step.startIndex..., in: step)),
              let range = Range(match.range(at: 1), in: step) else { return nil }
        return String(step[range]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Safety

    /// Steps System One never runs on its own: System Two asks first.
    static func isRisky(_ step: String) -> Bool {
        step.range(of: #"\b(?:send|delete|remove|erase|trash|buy|purchase|pay|checkout|check out|order|submit|post|publish|transfer|quit|shut ?down|restart|log ?out|sign ?out|uninstall|format|empty)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}
