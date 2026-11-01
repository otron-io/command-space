//
//  Calculator.swift
//  Command Space
//
//  Inline arithmetic: "12*(3+4)", "2^10", "15% of 80", "1,200 / 3". A small recursive-descent
//  parser (NSExpression raises Objective-C exceptions on bad input, so it's not used).
//

import Foundation

enum Calculator {
    /// In locales with a decimal comma, "1,5" is one and a half; elsewhere "1,200" is twelve hundred.
    static func evaluate(_ input: String, locale: Locale = .current) -> Double? {
        let decimalComma = locale.decimalSeparator == ","
        var text = input.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " x ", with: "*")
            .replacingOccurrences(of: ",", with: decimalComma ? "." : "")
            .trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        // "15% of 80"
        if let match = text.range(of: #"^\s*([\d.]+)\s*%\s*of\s*([\d.]+)\s*$"#, options: .regularExpression) {
            let parts = text[match].components(separatedBy: CharacterSet(charactersIn: "%of ")).compactMap(Double.init)
            if parts.count == 2 { return parts[0] / 100 * parts[1] }
        }
        // Must look like math: only these characters, at least one operator, at least one digit.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^()% ")
        guard text.unicodeScalars.allSatisfy(allowed.contains),
              text.contains(where: \.isNumber),
              text.contains(where: { "+-*/^%".contains($0) }) || text.contains("(") else { return nil }
        var parser = Parser(Array(text.filter { $0 != " " }))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return Int64(value).formatted(.number.grouping(.automatic).locale(locale))
        }
        return value.formatted(.number.precision(.significantDigits(1...12)).grouping(.automatic).locale(locale))
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i == chars.count }
        private var peek: Character? { i < chars.count ? chars[i] : nil }

        // expression := term (('+'|'-') term)*
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := power (('*'|'/'|'%') power)*
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek, op == "*" || op == "/" || op == "%" {
                i += 1
                // Trailing "%" means percent: "50%" → 0.5
                if op == "%", peek == nil || peek == ")" || peek == "+" || peek == "-" {
                    value /= 100
                    continue
                }
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        // power := unary ('^' power)?
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                i += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek == "-" { i += 1; return unary().map { -$0 } }
            if peek == "+" { i += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if peek == "(" {
                i += 1
                let value = expression()
                guard peek == ")" else { return nil }
                i += 1
                return value
            }
            let start = i
            while let c = peek, c.isNumber || c == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(chars[start..<i]))
        }
    }
}
