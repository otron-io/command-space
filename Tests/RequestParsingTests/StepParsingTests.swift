import XCTest
@testable import CommandSpace

final class StepParsingTests: XCTestCase {
    func testSplitsChains() {
        XCTAssertEqual(StepParsing.split("open notes and create a new note and add text saying Hello world"),
                       ["open notes", "create a new note", "add text saying Hello world"])
        XCTAssertEqual(StepParsing.split("Open Notes, create a new note, and add text saying hello world."),
                       ["Open Notes", "create a new note", "add text saying hello world"])
        XCTAssertEqual(StepParsing.split("open safari then press command t"), ["open safari", "press command t"])
    }

    func testKeepsTextWithAnd() {
        XCTAssertEqual(StepParsing.split("type salt and pepper and press enter"), ["type salt and pepper", "press enter"])
        XCTAssertEqual(StepParsing.split("type \"open and close\" then press enter"), ["type \"open and close\"", "press enter"])
    }

    func testDoesNotSplitRemindersOrQuestions() {
        XCTAssertEqual(StepParsing.split("remind me to call mom and send the report").count, 1)
        XCTAssertEqual(StepParsing.split("what is the weather and should I open a window").count, 1)
    }

    func testLocalSteps() {
        XCTAssertEqual(StepParsing.local("add text saying Hello world"), .type("Hello world"))
        XCTAssertEqual(StepParsing.local("type “Dear Sam,”"), .type("Dear Sam,"))
        XCTAssertEqual(StepParsing.local("open notes"), .open("notes"))
        XCTAssertEqual(StepParsing.local("wait 2 seconds"), .wait(2))
        guard case .press(let chord, let times) = StepParsing.local("press command shift n twice") else { return XCTFail() }
        XCTAssertEqual(chord.keyCode, 45)
        XCTAssertEqual(chord.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(times, 2)
        guard case .press(let enter, _) = StepParsing.local("hit enter") else { return XCTFail() }
        XCTAssertEqual(enter.keyCode, 36)
        XCTAssertNil(StepParsing.local("create a new note"))
        XCTAssertNil(StepParsing.local("type in the search field"))
    }

    func testRiskySteps() {
        XCTAssertTrue(StepParsing.isRisky("send it"))
        XCTAssertTrue(StepParsing.isRisky("delete the note"))
        XCTAssertFalse(StepParsing.isRisky("create a new note"))
    }

    func testStopPhrases() {
        XCTAssertTrue(PushToTalk.isStopPhrase("Stop listening."))
        XCTAssertFalse(PushToTalk.isStopPhrase("stop the music"))
    }
}
