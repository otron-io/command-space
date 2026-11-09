import XCTest
@testable import CommandSpace

final class TranslationParsingTests: XCTestCase {
    private func parse(_ q: String, _ selection: String? = nil) -> TranslationRequest? {
        TranslationParsing.parse(q, selection: selection)
    }

    func testExplicitTargets() {
        XCTAssertEqual(parse("translate good morning to french")?.text, "good morning")
        XCTAssertEqual(parse("translate good morning to french")?.target.languageCode?.identifier, "fr")
        XCTAssertEqual(parse("translate to German: where is the station")?.text, "where is the station")
        XCTAssertEqual(parse("how do you say thank you in japanese?")?.target.languageCode?.identifier, "ja")
        XCTAssertEqual(parse("gracias in english")?.text, "gracias")
        XCTAssertEqual(parse("translate \"bonjour\" from french to english")?.source?.languageCode?.identifier, "fr")
        XCTAssertEqual(parse("translate hello into chinese")?.target.script?.identifier ?? "Hans", "Hans")
    }

    func testSelection() {
        let request = parse("translate this to spanish", "The meeting moved to Thursday.")
        XCTAssertEqual(request?.text, "The meeting moved to Thursday.")
        XCTAssertEqual(request?.fromSelection, true)
        XCTAssertNotNil(parse("translate", "Wo ist der Bahnhof?"))
        XCTAssertNil(parse("translate this to spanish"))  // nothing selected
        XCTAssertNil(parse("translate"))
    }

    func testNotTranslations() {
        XCTAssertNil(parse("safari"))
        XCTAssertNil(parse("weather in paris"))
        XCTAssertNil(parse("what is the capital of france"))
    }

    func testDetection() {
        XCTAssertEqual(TranslationParsing.detect("Où est la gare, s'il vous plaît ?")?.languageCode?.identifier, "fr")
    }
}
