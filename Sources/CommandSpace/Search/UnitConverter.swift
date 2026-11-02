// Local, deterministic conversions. No model, network, or changing exchange rates.
import Foundation

enum UnitConverter {
    struct Result: Equatable {
        let value: Double
        let unit: String
        let source: String
        var answer: String { "\(Calculator.format(value)) \(unit)" }
    }

    private struct Unit {
        let dimension: String
        let symbol: String
        let scale: Double
        var offset: Double = 0
        let aliases: [String]
    }

    /// Values are converted through a base unit; temperature also has an offset.
    private static let units: [Unit] = [
        .init(dimension: "length", symbol: "mm", scale: 0.001, aliases: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]),
        .init(dimension: "length", symbol: "cm", scale: 0.01, aliases: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"]),
        .init(dimension: "length", symbol: "m", scale: 1, aliases: ["m", "meter", "meters", "metre", "metres"]),
        .init(dimension: "length", symbol: "km", scale: 1000, aliases: ["km", "kilometer", "kilometers", "kilometre", "kilometres"]),
        .init(dimension: "length", symbol: "in", scale: 0.0254, aliases: ["in", "inch", "inches", "\"", "″"]),
        .init(dimension: "length", symbol: "ft", scale: 0.3048, aliases: ["ft", "foot", "feet", "'", "′"]),
        .init(dimension: "length", symbol: "yd", scale: 0.9144, aliases: ["yd", "yard", "yards"]),
        .init(dimension: "length", symbol: "mi", scale: 1609.344, aliases: ["mi", "mile", "miles"]),
        .init(dimension: "mass", symbol: "mg", scale: 0.000001, aliases: ["mg", "milligram", "milligrams"]),
        .init(dimension: "mass", symbol: "g", scale: 0.001, aliases: ["g", "gram", "grams"]),
        .init(dimension: "mass", symbol: "kg", scale: 1, aliases: ["kg", "kilogram", "kilograms", "kilo", "kilos"]),
        .init(dimension: "mass", symbol: "oz", scale: 0.028349523125, aliases: ["oz", "ounce", "ounces"]),
        .init(dimension: "mass", symbol: "lb", scale: 0.45359237, aliases: ["lb", "lbs", "pound", "pounds"]),
        .init(dimension: "mass", symbol: "st", scale: 6.35029318, aliases: ["st", "stone", "stones"]),
        .init(dimension: "temperature", symbol: "°C", scale: 1, offset: 273.15, aliases: ["c", "°c", "celsius", "degrees celsius"]),
        .init(dimension: "temperature", symbol: "°F", scale: 5.0 / 9, offset: 459.67 * 5 / 9, aliases: ["f", "°f", "fahrenheit", "degrees fahrenheit"]),
        .init(dimension: "temperature", symbol: "K", scale: 1, aliases: ["k", "kelvin"]),
        .init(dimension: "volume", symbol: "mL", scale: 0.001, aliases: ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]),
        .init(dimension: "volume", symbol: "L", scale: 1, aliases: ["l", "liter", "liters", "litre", "litres"]),
        .init(dimension: "volume", symbol: "US gal", scale: 3.785411784, aliases: ["gal", "gallon", "gallons", "us gal", "us gallon", "us gallons"]),
        .init(dimension: "volume", symbol: "imp gal", scale: 4.54609, aliases: ["imp gal", "imperial gallon", "imperial gallons", "uk gallon", "uk gallons"]),
        .init(dimension: "volume", symbol: "US fl oz", scale: 0.0295735295625, aliases: ["fl oz", "fluid ounce", "fluid ounces", "us fl oz"]),
        .init(dimension: "volume", symbol: "US cup", scale: 0.2365882365, aliases: ["cup", "cups", "us cup", "us cups"]),
        .init(dimension: "volume", symbol: "US tbsp", scale: 0.01478676478125, aliases: ["tbsp", "tablespoon", "tablespoons", "us tbsp"]),
        .init(dimension: "volume", symbol: "US tsp", scale: 0.00492892159375, aliases: ["tsp", "teaspoon", "teaspoons", "us tsp"]),
        .init(dimension: "time", symbol: "ms", scale: 0.001, aliases: ["ms", "millisecond", "milliseconds"]),
        .init(dimension: "time", symbol: "s", scale: 1, aliases: ["s", "sec", "secs", "second", "seconds"]),
        .init(dimension: "time", symbol: "min", scale: 60, aliases: ["min", "mins", "minute", "minutes"]),
        .init(dimension: "time", symbol: "h", scale: 3600, aliases: ["h", "hr", "hrs", "hour", "hours"]),
        .init(dimension: "time", symbol: "days", scale: 86400, aliases: ["d", "day", "days"]),
        .init(dimension: "time", symbol: "weeks", scale: 604800, aliases: ["week", "weeks", "wk"]),
        .init(dimension: "speed", symbol: "m/s", scale: 1, aliases: ["m/s", "mps", "meters per second", "metres per second"]),
        .init(dimension: "speed", symbol: "km/h", scale: 1 / 3.6, aliases: ["km/h", "kph", "kmh", "kilometers per hour", "kilometres per hour"]),
        .init(dimension: "speed", symbol: "mph", scale: 0.44704, aliases: ["mph", "mi/h", "miles per hour"]),
        .init(dimension: "speed", symbol: "kn", scale: 1852.0 / 3600, aliases: ["kn", "knot", "knots", "kts"]),
        .init(dimension: "area", symbol: "m²", scale: 1, aliases: ["m²", "m2", "sqm", "sq m", "square meters", "square metres"]),
        .init(dimension: "area", symbol: "ft²", scale: 0.09290304, aliases: ["ft²", "ft2", "sqft", "sq ft", "square feet"]),
        .init(dimension: "area", symbol: "km²", scale: 1e6, aliases: ["km²", "km2", "sq km", "square kilometers", "square kilometres"]),
        .init(dimension: "area", symbol: "acres", scale: 4046.8564224, aliases: ["acre", "acres"]),
        .init(dimension: "area", symbol: "ha", scale: 10000, aliases: ["ha", "hectare", "hectares"]),
        .init(dimension: "energy", symbol: "J", scale: 1, aliases: ["j", "joule", "joules"]),
        .init(dimension: "energy", symbol: "kJ", scale: 1000, aliases: ["kj", "kilojoule", "kilojoules"]),
        .init(dimension: "energy", symbol: "kcal", scale: 4184, aliases: ["kcal", "calorie", "calories", "kilocalorie", "kilocalories"]),
        .init(dimension: "energy", symbol: "kWh", scale: 3.6e6, aliases: ["kwh", "kilowatt hour", "kilowatt hours"]),
        .init(dimension: "pressure", symbol: "Pa", scale: 1, aliases: ["pa", "pascal", "pascals"]),
        .init(dimension: "pressure", symbol: "kPa", scale: 1000, aliases: ["kpa"]),
        .init(dimension: "pressure", symbol: "bar", scale: 100000, aliases: ["bar"]),
        .init(dimension: "pressure", symbol: "psi", scale: 6894.757293168, aliases: ["psi"]),
        .init(dimension: "pressure", symbol: "atm", scale: 101325, aliases: ["atm", "atmosphere", "atmospheres"]),
        .init(dimension: "angle", symbol: "°", scale: .pi / 180, aliases: ["deg", "degree", "degrees", "°"]),
        .init(dimension: "angle", symbol: "rad", scale: 1, aliases: ["rad", "radian", "radians"]),
    ]

    private static func unit(_ raw: String) -> Unit? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        // SI byte/bit symbols are case sensitive: MB is megabytes, Mb is megabits.
        let prefixes: [(String, Double)] = [("", 1), ("k", 1e3), ("K", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("Ki", 1024), ("Mi", 1048576), ("Gi", 1073741824), ("Ti", 1099511627776)]
        for (prefix, scale) in prefixes {
            if text == prefix + "B" { return .init(dimension: "data", symbol: text, scale: scale * 8, aliases: []) }
            if text == prefix + "b" { return .init(dimension: "data", symbol: text, scale: scale, aliases: []) }
        }
        let words: [(String, String, Double)] = [("byte", "B", 8), ("bit", "b", 1), ("kilobyte", "kB", 8e3), ("megabyte", "MB", 8e6), ("gigabyte", "GB", 8e9), ("terabyte", "TB", 8e12), ("kilobit", "kb", 1e3), ("megabit", "Mb", 1e6), ("gigabit", "Gb", 1e9)]
        let lower = text.lowercased()
        for (word, symbol, scale) in words where lower == word || lower == word + "s" {
            return .init(dimension: "data", symbol: symbol, scale: scale, aliases: [])
        }
        return units.first { $0.aliases.contains(lower) }
    }

    static func evaluate(_ input: String, locale: Locale = .current) -> Result? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        let pattern = #"^(?:convert\s+)?([+-]?(?:\d[\d.,]*|[.,]\d+)(?:[eE][+-]?\d+)?)\s*(.+?)\s+(?:to|in|into|as|=|→)\s+(.+?)\s*\??$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text),
              let value = number(String(text[numberRange]), locale: locale),
              let from = unit(String(text[fromRange])), let to = unit(String(text[toRange])),
              from.dimension == to.dimension else { return nil }
        let base = value * from.scale + from.offset
        // Temperatures below absolute zero are not physical conversions.
        guard from.dimension != "temperature" || base >= -1e-10 else { return nil }
        let result = (base - to.offset) / to.scale
        guard result.isFinite else { return nil }
        return Result(value: from.dimension == "temperature" && abs(result) < 1e-12 ? 0 : result, unit: to.symbol,
                      source: "\(Calculator.format(value, locale: locale)) \(from.symbol)")
    }

    private static func number(_ raw: String, locale: Locale) -> Double? {
        var text = raw
        if locale.decimalSeparator == "," {
            // Accept a dot decimal too, just like the calculator; mixed punctuation is localized.
            if text.contains(",") { text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        } else if text.contains(",") {
            // A misplaced comma must not silently turn 1,5 into 15.
            guard text.range(of: #"^[+-]?\d{1,3}(?:,\d{3})+(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// Integer base conversion is another instant result, with explicit source prefixes.
    static func numberBase(_ input: String) -> String? {
        let pattern = #"^(0x[0-9a-f]+|0b[01]+|0o[0-7]+|[0-9]+)\s+(?:to|in|as)\s+(hex|hexadecimal|binary|bin|octal|decimal|dec)$"#
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let source = Range(match.range(at: 1), in: text), let target = Range(match.range(at: 2), in: text) else { return nil }
        let raw = String(text[source])
        let base = raw.hasPrefix("0x") ? 16 : raw.hasPrefix("0b") ? 2 : raw.hasPrefix("0o") ? 8 : 10
        guard let value = UInt64(base == 10 ? raw : String(raw.dropFirst(2)), radix: base) else { return nil }
        switch text[target] {
        case "hex", "hexadecimal": return "0x" + String(value, radix: 16).uppercased()
        case "binary", "bin": return "0b" + String(value, radix: 2)
        case "octal": return "0o" + String(value, radix: 8)
        default: return String(value)
        }
    }
}
