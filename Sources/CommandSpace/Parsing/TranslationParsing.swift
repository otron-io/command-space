//
//  TranslationParsing.swift
//  Command Space
//
//  Recognises translation requests in plain code: "translate this to French",
//  "gracias in english", "how do you say good morning in Japanese", or just "translate"
//  with text selected. The translating itself happens on this Mac (Translator).
//

import Foundation
import NaturalLanguage

struct TranslationRequest: Equatable {
    var text: String
    /// nil: detect from the text.
    var source: Locale.Language?
    var target: Locale.Language
    /// The text is the user's selection, not something they typed.
    var fromSelection: Bool
}

enum TranslationParsing {
    /// Languages Apple's on-device translation covers.
    static let languageCodes = ["ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it", "ja", "ko",
                                "pl", "pt", "ru", "es", "th", "tr", "uk", "vi"]

    private static let aliases: [String: String] = [
        "chinese": "zh-Hans", "mandarin": "zh-Hans", "simplified chinese": "zh-Hans", "traditional chinese": "zh-Hant",
        "cantonese": "zh-Hant", "brazilian": "pt", "brazilian portuguese": "pt", "farsi": "", "dutch": "nl", "flemish": "nl",
        "english": "en", "american": "en", "british": "en", "castilian": "es", "mexican": "es", "indonesian": "id",
        "bahasa": "id", "ukrainian": "uk", "vietnamese": "vi", "thai": "th", "turkish": "tr", "polish": "pl",
    ]

    /// "french" → fr, in English and in the user's own language ("französisch").
    static let languageNames: [String: String] = {
        var names: [String: String] = [:]
        let locales = [Locale(identifier: "en"), Locale.current]
        for code in languageCodes {
            for locale in locales {
                if let name = locale.localizedString(forIdentifier: code)?.lowercased() { names[name] = code }
                if let name = locale.localizedString(forLanguageCode: code)?.lowercased(), names[name] == nil { names[name] = code }
            }
        }
        for (alias, code) in aliases where !code.isEmpty { names[alias] = code }
        return names
    }()

    private static let namePattern: String = {
        languageNames.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }()

    static func language(named name: String) -> Locale.Language? {
        languageNames[name.lowercased().trimmingCharacters(in: .whitespaces)].map { Locale.Language(identifier: $0) }
    }

    /// - Parameter selection: the text selected in the app the user came from, if any.
    static func parse(_ query: String, selection: String?) -> TranslationRequest? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        guard !q.isEmpty else { return nil }
        let lang = "(\(namePattern))"
        let selected = selection?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let opts: NSString.CompareOptions = [.regularExpression, .caseInsensitive]

        func groups(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: q).map { String(q[$0]) } }
        }
        func request(text: String?, from: String?, to: String?) -> TranslationRequest? {
            var body = text?.trimmingCharacters(in: .whitespaces) ?? ""
            body = unquote(body)
            let referent = body.isEmpty || body.range(of: #"^(?:this|that|it|these|the selection|selection|selected text|the selected text|the text|this text|highlighted text|the highlighted text)$"#, options: opts) != nil
            let usesSelection = referent
            guard let source = usesSelection ? selected : body.nilIfEmpty else { return nil }
            let target = to.flatMap(language(named:)) ?? defaultTarget(for: source)
            guard let target else { return nil }
            return TranslationRequest(text: source, source: from.flatMap(language(named:)), target: target, fromSelection: usesSelection)
        }

        // "translate X from Spanish to English", "translate X to French", "translate to French: X", "translate X"
        if let g = groups(#"(?:please\s+)?translate\s+(.+?)\s+from\s+"# + lang + #"\s+(?:to|into)\s+"# + lang) {
            return request(text: g[0], from: g[1], to: g[2])
        }
        if let g = groups(#"(?:please\s+)?translate\s+(?:(.+?)\s+)?(?:to|into|in)\s+"# + lang) {
            return request(text: g[0], from: nil, to: g[1])
        }
        if let g = groups(#"(?:please\s+)?translate\s+(?:to|into)\s+"# + lang + #"\s*:?\s+(.+)"#) {
            return request(text: g[1], from: nil, to: g[0])
        }
        if let g = groups(#"(?:please\s+)?translate(?:\s+(.+))?"#) {
            return request(text: g[0], from: nil, to: nil)
        }
        // "how do you say X in Japanese", "what is X in English", "X in French"
        if let g = groups(#"(?:how (?:do|would) (?:you|i) say|what(?:'s| is| does)|say)\s+(.+?)\s+(?:in|en)\s+"# + lang) {
            return request(text: g[0], from: nil, to: g[1])
        }
        if let g = groups(#"(.+?)\s+in\s+"# + lang) {
            // Only quoted text or a short phrase: "files in english" style searches stay searches.
            guard let text = g[0], text.split(separator: " ").count <= 8 else { return nil }
            return request(text: text, from: nil, to: g[1])
        }
        // "English: X", "to French X"
        if let g = groups(#"(?:to\s+)?"# + lang + #"\s*:\s*(.+)"#) {
            return request(text: g[1], from: nil, to: g[0])
        }
        return nil
    }

    /// The user's own language, unless the text is already in it (then English).
    static func defaultTarget(for text: String) -> Locale.Language? {
        let mine = Locale.current.language
        let detected = detect(text)
        if let detected, detected.languageCode != mine.languageCode { return Locale.Language(identifier: mine.languageCode?.identifier ?? "en") }
        if mine.languageCode?.identifier != "en" { return Locale.Language(identifier: "en") }
        return nil
    }

    static func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languageCodes.map { NLLanguage($0) } + [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value > 0.3 else { return nil }
        return Locale.Language(identifier: best.key.rawValue)
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              "\"“'‘".contains(first), "\"”'’".contains(last) else { return text }
        return String(text.dropFirst().dropLast())
    }

    static func displayName(_ language: Locale.Language) -> String {
        let id = language.maximalIdentifier
        let code = language.languageCode?.identifier ?? id
        if code == "zh" { return language.script?.identifier == "Hant" ? "Chinese (Traditional)" : "Chinese" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
