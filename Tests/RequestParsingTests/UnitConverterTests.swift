import XCTest
@testable import CommandSpace

final class UnitConverterTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func convert(_ query: String, _ expected: Double, unit: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
        guard let result = UnitConverter.evaluate(query, locale: us) else {
            return XCTFail("No conversion for \(query)", file: file, line: line)
        }
        XCTAssertEqual(result.value, expected, accuracy: max(1e-10, abs(expected) * 1e-10), file: file, line: line)
        if let unit { XCTAssertEqual(result.unit, unit, file: file, line: line) }
    }

    func testLengthsAndAliases() {
        convert("10km to miles", 6.21371192237334, unit: "mi")
        convert("convert 12 inches into cm", 30.48)
        convert("1 meter in feet", 3.28083989501312)
        convert("1 yd = inches", 36)
        convert("2.5 kilometres → m", 2500)
    }

    func testMass() {
        convert("70 kg to lbs", 154.323583529414)
        convert("16 oz in pounds", 1)
        convert("1 stone to lb", 14)
    }

    func testTemperature() {
        convert("32 F to C", 0, unit: "°C")
        convert("100 celsius to fahrenheit", 212)
        convert("-40°F in °C", -40)
        convert("0 K to C", -273.15)
        XCTAssertNil(UnitConverter.evaluate("-274 C to F", locale: us))
    }

    func testTimeSpeedAreaEnergyPressureAndAngles() {
        convert("90 min to hours", 1.5)
        convert("2 days in seconds", 172800)
        convert("60 mph to km/h", 96.56064)
        convert("1 m/s to kph", 3.6)
        convert("1000 sq ft in m2", 92.90304)
        convert("1 acre to ha", 0.40468564224)
        convert("1 kWh to kJ", 3600)
        convert("1 bar to kPa", 100)
        convert("180 degrees to radians", .pi)
    }

    func testVolumeConventionsAreExplicit() {
        convert("1 gallon in liters", 3.785411784, unit: "L")
        convert("1 imperial gallon to l", 4.54609)
        let cup = UnitConverter.evaluate("250 ml in cups", locale: us)
        XCTAssertEqual(cup?.unit, "US cup")
        XCTAssertEqual(UnitConverter.evaluate("1 gallon to cups", locale: us)?.source, "1 US gal")
    }

    func testBytesBitsAndBinaryPrefixes() {
        convert("1 GB to MB", 1000)
        convert("1 GiB to MiB", 1024)
        convert("8 Mb to MB", 1)
        convert("1 B to b", 8)
        convert("1 megabyte in kilobits", 8000)
        convert("1 TB to GB", 1000)
    }

    func testLocaleAndScientificNotation() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(UnitConverter.evaluate("1,5 km to m", locale: german)?.value, 1500)
        XCTAssertEqual(UnitConverter.evaluate("1.5 km to m", locale: german)?.value, 1500)
        XCTAssertEqual(UnitConverter.evaluate("1.234,5 m to km", locale: german)?.value, 1.2345)
        convert("1,200 m to km", 1.2)
        convert("1e3 m to km", 1)
        XCTAssertNil(UnitConverter.evaluate("1,5 km to m", locale: us))
        XCTAssertNil(UnitConverter.evaluate("1,23,456 m to km", locale: us))
    }

    func testUnrelatedOrInvalidRequestsDoNotConvert() {
        for query in ["safari", "go to 10 Downing street", "set volume to 50", "5 kg to meters", "5 cups to grams",
                      "100 usd to eur", "10 km", "10 km to", "infinity m to km", "1e999 m to km", "5 minutes until my meeting",
                      "what is 5 kg in pounds and can you order some"] {
            XCTAssertNil(UnitConverter.evaluate(query, locale: us), query)
        }
    }

    func testNumberBases() {
        XCTAssertEqual(UnitConverter.numberBase("255 to hex"), "0xFF")
        XCTAssertEqual(UnitConverter.numberBase("0xFF in decimal"), "255")
        XCTAssertEqual(UnitConverter.numberBase("42 to binary"), "0b101010")
        XCTAssertEqual(UnitConverter.numberBase("0b101010 to decimal"), "42")
        XCTAssertEqual(UnitConverter.numberBase("64 to octal"), "0o100")
        XCTAssertNil(UnitConverter.numberBase("0b102 to hex"))
        XCTAssertNil(UnitConverter.numberBase("18446744073709551616 to hex"))
    }

    @MainActor func testLocalAnswersBypassModelRanking() {
        XCTAssertTrue(SearchEngine.hasLocalAnswer("2+3"))
        XCTAssertTrue(SearchEngine.hasLocalAnswer("10 km to miles"))
        XCTAssertTrue(SearchEngine.hasLocalAnswer("255 to hex"))
        XCTAssertFalse(SearchEngine.hasLocalAnswer("explain this page"))
    }
}
