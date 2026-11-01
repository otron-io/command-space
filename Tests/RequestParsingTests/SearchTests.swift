import XCTest
@testable import CommandSpace

final class FuzzyMatchTests: XCTestCase {
    func testOrdering() {
        let exact = FuzzyMatch.score("safari", in: "Safari")
        let prefix = FuzzyMatch.score("saf", in: "Safari")
        let word = FuzzyMatch.score("code", in: "Visual Studio Code")
        let initials = FuzzyMatch.score("vsc", in: "Visual Studio Code")
        let scattered = FuzzyMatch.score("vsd", in: "Visual Studio Code")
        XCTAssertEqual(exact, 1)
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, initials)
        XCTAssertGreaterThan(initials, scattered)
        XCTAssertGreaterThan(scattered, 0)
    }

    func testCamelCaseAndInitialsThenPrefix() {
        XCTAssertGreaterThan(FuzzyMatch.score("storm", in: "PhpStorm"), 0.8)
        XCTAssertGreaterThan(FuzzyMatch.score("vscode", in: "Visual Studio Code"), 0.7)
    }

    func testNoMatch() {
        XCTAssertEqual(FuzzyMatch.score("xyz", in: "Safari"), 0)
        XCTAssertEqual(FuzzyMatch.score("", in: "Safari"), 0)
    }
}

final class CalculatorTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    func testDecimalComma() {
        XCTAssertEqual(Calculator.evaluate("1,5 + 1", locale: de), 2.5)
        XCTAssertEqual(Calculator.evaluate("1.5 + 1", locale: de), 2.5)
        XCTAssertEqual(Calculator.evaluate("1,200 / 3", locale: us), 400)
        XCTAssertEqual(Calculator.format(0.5, locale: de), "0,5")
    }

    func testArithmetic() {
        XCTAssertEqual(Calculator.evaluate("2+3*4"), 14)
        XCTAssertEqual(Calculator.evaluate("(2+3)*4"), 20)
        XCTAssertEqual(Calculator.evaluate("2^10"), 1024)
        XCTAssertEqual(Calculator.evaluate("-3 + 5"), 2)
        XCTAssertEqual(Calculator.evaluate("12 × 3"), 36)
        XCTAssertEqual(Calculator.evaluate("50%"), 0.5)
        XCTAssertEqual(Calculator.evaluate("15% of 80"), 12)
    }

    func testNotMath() {
        XCTAssertNil(Calculator.evaluate("safari"))
        XCTAssertNil(Calculator.evaluate("2024"))           // a bare number isn't a calculation
        XCTAssertNil(Calculator.evaluate("(2+3"))
        XCTAssertNil(Calculator.evaluate("1/0"))            // not finite
        XCTAssertNil(Calculator.evaluate("volume 50"))
    }

    func testFormat() {
        XCTAssertEqual(Calculator.format(1024, locale: us), "1,024")
        XCTAssertEqual(Calculator.format(0.5, locale: us), "0.5")
    }
}

final class QuickOpenTests: XCTestCase {
    func testWebURLs() {
        XCTAssertEqual(QuickOpen.webURL(from: "github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(QuickOpen.webURL(from: "news.ycombinator.com/item?id=1")?.absoluteString, "https://news.ycombinator.com/item?id=1")
        XCTAssertEqual(QuickOpen.webURL(from: "localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(QuickOpen.webURL(from: "https://x.ai")?.absoluteString, "https://x.ai")
    }

    func testWebSearchEncoding() {
        XCTAssertEqual(QuickOpen.webSearchURL("c++ & rust")?.absoluteString,
                       "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    func testNotURLs() {
        XCTAssertNil(QuickOpen.webURL(from: "safari"))
        XCTAssertNil(QuickOpen.webURL(from: "open github"))
        XCTAssertNil(QuickOpen.webURL(from: "report.pdf"))
        XCTAssertNil(QuickOpen.webURL(from: "3.14"))
    }
}
