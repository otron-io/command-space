import Defaults
import XCTest
@testable import CommandSpace

final class ComputerUseTests: XCTestCase {
    private func actions(_ arguments: Any?) -> [ComputerAction]? {
        if case .success(let list) = ComputerActions.parse(arguments) { return list }
        return nil
    }

    private func failure(_ arguments: Any?) -> String? {
        if case .failure(let error) = ComputerActions.parse(arguments) { return error.message }
        return nil
    }

    func testParsesEachKind() {
        let list = actions(["actions": [
            ["type": "screenshot"],
            ["type": "click", "x": 412, "y": 300],
            ["type": "double_click", "x": 10, "y": 20],
            ["type": "right_click", "x": 1, "y": 2],
            ["type": "click", "x": 5, "y": 6, "button": "middle"],
            ["type": "move", "x": 7, "y": 8],
            ["type": "scroll", "x": 100, "y": 100, "scroll_y": 300],
            ["type": "type", "text": "hello"],
            ["type": "keypress", "keys": ["CMD", "C"]],
            ["type": "wait", "seconds": 2],
            ["type": "open_app", "name": "Calculator"],
            ["type": "drag", "path": [["x": 0, "y": 0], ["x": 50, "y": 60]]],
        ]])
        XCTAssertEqual(list, [
            .screenshot,
            .click(x: 412, y: 300, button: .left, count: 1),
            .click(x: 10, y: 20, button: .left, count: 2),
            .click(x: 1, y: 2, button: .right, count: 1),
            .click(x: 5, y: 6, button: .middle, count: 1),
            .move(x: 7, y: 8),
            .scroll(x: 100, y: 100, dx: 0, dy: 300),
            .type("hello"),
            .keypress(["CMD", "C"]),
            .wait(seconds: 2),
            .openApp("Calculator"),
            .drag(path: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 60)]),
        ])
    }

    func testAliasesAndNumericStrings() {
        XCTAssertEqual(actions(["actions": [["action": "LEFT_CLICK", "x": "12.5", "y": "9"]]]),
                       [.click(x: 12.5, y: 9, button: .left, count: 1)])
        XCTAssertEqual(actions(["actions": [["type": "triple_click", "x": 1, "y": 1]]]),
                       [.click(x: 1, y: 1, button: .left, count: 3)])
        XCTAssertEqual(actions(["actions": [["type": "click", "x": 1, "y": 1, "clicks": 2]]]),
                       [.click(x: 1, y: 1, button: .left, count: 2)])
        XCTAssertEqual(actions(["actions": [["type": "hotkey", "keys": "cmd+shift+p"]]]), [.keypress(["cmd", "shift", "p"])])
        XCTAssertEqual(actions(["actions": [["type": "key", "key": "enter"]]]), [.keypress(["enter"])])
        XCTAssertEqual(actions(["actions": [["type": "wait", "ms": 500]]]), [.wait(seconds: 0.5)])
        XCTAssertEqual(actions(["actions": [["type": "wait", "seconds": 99]]]), [.wait(seconds: 10)])
        XCTAssertEqual(actions(["actions": [["type": "wait"]]]), [.wait(seconds: 1)])
        XCTAssertEqual(actions(["actions": [["type": "open_application", "app": "Notes"]]]), [.openApp("Notes")])
        XCTAssertEqual(actions(["actions": [["type": "scroll", "x": 1, "y": 2, "dx": 5, "dy": -7]]]),
                       [.scroll(x: 1, y: 2, dx: 5, dy: -7)])
        XCTAssertEqual(actions(["actions": [["type": "drag", "from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4]]]]),
                       [.drag(path: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])])
        XCTAssertEqual(actions(["actions": [["type": "left_click_drag", "start_x": 1, "start_y": 2, "end_x": 3, "end_y": 4]]]),
                       [.drag(path: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])])
        XCTAssertEqual(actions(["actions": [["type": "drag", "path": [[1, 2], [3, 4]]]]]),
                       [.drag(path: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])])
    }

    func testJSONStringTopLevelSingleAndEmpty() {
        XCTAssertEqual(actions("{\"actions\":[{\"type\":\"click\",\"x\":3,\"y\":4}]}"),
                       [.click(x: 3, y: 4, button: .left, count: 1)])
        XCTAssertEqual(actions(["type": "type", "text": "hi"]), [.type("hi")])
        XCTAssertEqual(actions([["type": "screenshot"], ["type": "wait", "seconds": 1]]), [.screenshot, .wait(seconds: 1)])
        XCTAssertEqual(actions(nil), [.screenshot])
        XCTAssertEqual(actions([String: Any]()), [.screenshot])
        XCTAssertEqual(actions(["actions": [Any]()]), [.screenshot])
    }

    func testErrors() {
        let many = (0..<21).map { _ in ["type": "screenshot"] }
        XCTAssertNotNil(failure(["actions": many]))
        XCTAssertEqual(failure(["actions": [["type": "screenshot"], ["type": "wait"], ["type": "click", "x": 1]]]),
                       "actions[2] (click) needs x and y")
        XCTAssertEqual(failure(["actions": [["type": "type"]]]), "actions[0] (type) needs text")
        XCTAssertTrue(failure(["actions": [["type": "teleport"]]])?.contains("screenshot") == true)
        XCTAssertNotNil(failure("not json"))
    }

    func testKeyStrokes() {
        XCTAssertEqual(ComputerActions.keyStrokes(for: ["CMD", "SHIFT", "P"]),
                       [.init(keyCode: 35, flags: [.maskCommand, .maskShift], label: "⌘⇧P")])
        XCTAssertEqual(ComputerActions.keyStrokes(for: ["ENTER"])?.first?.keyCode, 36)
        XCTAssertEqual(ComputerActions.keyStrokes(for: ["DOWN", "DOWN"])?.map(\.keyCode), [125, 125])
        XCTAssertEqual(ComputerActions.keyStrokes(for: ["DELETE"])?.first?.keyCode, 51)
        XCTAssertEqual(ComputerActions.keyStrokes(for: ["ctrl", "`"])?.first?.keyCode, 50)
        XCTAssertNil(ComputerActions.keyStrokes(for: ["CMD", "BANANA"]))
        XCTAssertNil(ComputerActions.keyStrokes(for: ["CMD", "SHIFT"]))
    }

    func testScreenGeometry() {
        XCTAssertEqual(ScreenGeometry.imageSize(for: CGSize(width: 1512, height: 982)), CGSize(width: 1512, height: 982))
        let big = ScreenGeometry.imageSize(for: CGSize(width: 3008, height: 1692))
        XCTAssertEqual(big.width, 1600)
        XCTAssertEqual(big.height, 900)

        let geometry = ScreenGeometry(frame: CGRect(x: -1512, y: 100, width: 3008, height: 1692), imageSize: big)
        let point = geometry.point(x: 800, y: 450)
        XCTAssertEqual(point.x, -1512 + 1504, accuracy: 0.01)
        XCTAssertEqual(point.y, 100 + 846, accuracy: 0.01)
        let back = geometry.pixel(for: point)
        XCTAssertEqual(back.x, 800, accuracy: 0.01)
        XCTAssertEqual(back.y, 450, accuracy: 0.01)
        // Off-screen requests stay inside the display.
        let clamped = geometry.point(x: 99999, y: -50)
        XCTAssertEqual(clamped.x, geometry.frame.maxX - 1, accuracy: 0.01)
        XCTAssertEqual(clamped.y, geometry.frame.minY + 1, accuracy: 0.01)
    }

    func testSummaries() {
        XCTAssertEqual(ComputerAction.click(x: 412, y: 300, button: .left, count: 1).summary, "Click (412, 300)")
        XCTAssertEqual(ComputerAction.click(x: 10, y: 20, button: .left, count: 2).summary, "Double-click (10, 20)")
        XCTAssertEqual(ComputerAction.click(x: 1, y: 2, button: .right, count: 1).summary, "Right-click (1, 2)")
        XCTAssertEqual(ComputerAction.type("hello").summary, "Type “hello”")
        XCTAssertEqual(ComputerAction.type(String(repeating: "a", count: 50)).summary, "Type “" + String(repeating: "a", count: 40) + "…”")
        XCTAssertEqual(ComputerAction.keypress(["cmd", "c"]).summary, "Press ⌘C")
        XCTAssertEqual(ComputerAction.scroll(x: 0, y: 0, dx: 0, dy: 200).summary, "Scroll down")
        XCTAssertEqual(ComputerAction.wait(seconds: 2).summary, "Wait 2s")
        XCTAssertEqual(ComputerAction.openApp("Calculator").summary, "Open Calculator")
        XCTAssertEqual(ComputerAction.screenshot.summary, "Look at the screen")
        XCTAssertTrue(ComputerAction.wait(seconds: 1).isReadOnly)
        XCTAssertFalse(ComputerAction.type("x").isReadOnly)

        XCTAssertEqual(ComputerActions.summary(of: ["actions": [["type": "click", "x": 1, "y": 2], ["type": "type", "text": "a"]]]),
                       "Click (1, 2) → Type “a”")
        let five = (0..<5).map { _ in ["type": "screenshot"] }
        XCTAssertEqual(ComputerActions.summary(of: ["actions": five]),
                       Array(repeating: "Look at the screen", count: 4).joined(separator: " → ") + " → …")
        XCTAssertEqual(ComputerActions.summary(of: ["actions": [["type": "nope"]]]), "")
    }
}

// MARK: - Permission rules

@MainActor
private final class FakeComputer: ComputerDriver {
    private(set) var batches: [[ComputerAction]] = []
    func perform(_ actions: [ComputerAction], shouldStop: @escaping () -> Bool) async -> ComputerResult {
        batches.append(actions)
        return ComputerResult(success: true, text: "ok", image: nil)
    }
}

@MainActor
final class ComputerToolRulesTests: XCTestCase {
    private let tool = ComputerTool.shared
    private let harness = SystemTwoHarness.claudeCode
    private var fake = FakeComputer()
    private var events: [AgentEvent] = []
    private var sessions: [String] = []
    private var previousSink: ((SystemTwoHarness, String, AgentEvent) -> Void)!
    private var previousEnabled = true

    private let click: [String: Any] = ["actions": [["type": "click", "x": 10, "y": 20]]]
    private let shot: [String: Any] = ["actions": [["type": "screenshot"]]]

    override func setUp() async throws {
        fake = FakeComputer()
        events = []
        sessions = []
        previousEnabled = Defaults[.computerUseEnabled]
        previousSink = AgentBackendSink.event
        tool.driver = fake
        tool.missingAccess = { nil }
        tool.headless = false
        Defaults[.computerUseEnabled] = true
        AgentBackendSink.event = { [unowned self] _, _, event in self.events.append(event) }
    }

    override func tearDown() async throws {
        for session in sessions { tool.turnEnded(session) }
        tool.driver = MacComputer.shared
        tool.missingAccess = { ComputerAccess.missingExplanation }
        tool.headless = false
        AgentBackendSink.event = previousSink
        Defaults[.computerUseEnabled] = previousEnabled
    }

    private func newSession() -> String {
        let id = UUID().uuidString
        sessions.append(id)
        return id
    }

    private func cards() -> [AgentPermission] {
        events.compactMap { if case .permission(let p) = $0 { return p } else { return nil } }
    }

    private func resolvedIDs() -> [String] {
        events.compactMap { if case .permissionResolved(let id) = $0 { return id } else { return nil } }
    }

    private func call(_ arguments: Any?, _ session: String, _ mode: AgentMode) async -> ComputerResult {
        await tool.call(arguments: arguments, session: session, harness: harness, mode: mode)
    }

    /// Starts a call that is expected to wait on a card, and returns once the card has been emitted.
    private func startCall(_ arguments: Any?, _ session: String, _ mode: AgentMode, cardsExpected: Int = 1) async -> Task<ComputerResult, Never> {
        let before = cards().count
        let task = Task { await self.call(arguments, session, mode) }
        for _ in 0..<100 where cards().count < before + cardsExpected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return task
    }

    func testInvalidArgumentsFail() async {
        let session = newSession()
        let result = await call(["actions": [["type": "click", "x": 1]]], session, .fullAccess)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("needs x and y"))
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertTrue(cards().isEmpty)
    }

    func testSettingOffFails() async {
        let session = newSession()
        tool.grantConversation(session)
        Defaults[.computerUseEnabled] = false
        let result = await call(click, session, .fullAccess)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("turned off"))
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertTrue(cards().isEmpty)
    }

    func testPlanModeOnlyAllowsLooking() async {
        let session = newSession()
        tool.grantConversation(session)
        let refused = await call(click, session, .plan)
        XCTAssertFalse(refused.success)
        XCTAssertTrue(refused.text.contains("Plan mode"))
        XCTAssertTrue(fake.batches.isEmpty)
        let looked = await call(shot, session, .plan)
        XCTAssertTrue(looked.success)
        XCTAssertEqual(fake.batches, [[.screenshot]])
        XCTAssertTrue(cards().isEmpty)
    }

    func testHeadlessWithoutGrantFails() async {
        tool.headless = true
        let result = await call(click, newSession(), .ask)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("not allowed"))
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertTrue(cards().isEmpty)
    }

    func testHeadlessAfterConversationGrantPerforms() async {
        tool.headless = true
        let session = newSession()
        tool.grantConversation(session)
        let result = await call(click, session, .ask)
        XCTAssertTrue(result.success)
        XCTAssertEqual(fake.batches.count, 1)
        XCTAssertTrue(cards().isEmpty)
    }

    func testHeadlessFullAccessNeedsNoGrant() async {
        tool.headless = true
        let result = await call(click, newSession(), .fullAccess)
        XCTAssertTrue(result.success)
        XCTAssertEqual(fake.batches.count, 1)
        XCTAssertTrue(cards().isEmpty)
    }

    func testHeadlessMissingAccessFails() async {
        tool.headless = true
        tool.missingAccess = { "Screen Recording is off" }
        let session = newSession()
        tool.grantConversation(session)
        let result = await call(click, session, .ask)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("Screen Recording is off"))
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertTrue(cards().isEmpty)
    }

    func testRejectRefuses() async {
        let session = newSession()
        let task = await startCall(click, session, .ask)
        let card = try! XCTUnwrap(cards().first)
        XCTAssertTrue(tool.resolve(card, with: .reject))
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("declined"))
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertEqual(resolvedIDs(), [card.id])
    }

    func testOnceLastsForTheTurn() async {
        let session = newSession()
        let task = await startCall(click, session, .ask)
        tool.resolve(try! XCTUnwrap(cards().first), with: .once)
        let first = await task.value
        XCTAssertTrue(first.success)
        XCTAssertEqual(fake.batches.count, 1)

        let second = await call(click, session, .ask)
        XCTAssertTrue(second.success)
        XCTAssertEqual(fake.batches.count, 2)
        XCTAssertEqual(cards().count, 1)

        tool.turnEnded(session)
        let next = await startCall(click, session, .ask)
        XCTAssertEqual(cards().count, 2)
        tool.resolve(cards()[1], with: .reject)
        let declined = await next.value
        XCTAssertFalse(declined.success)
        XCTAssertEqual(fake.batches.count, 2)
    }

    func testAlwaysLastsForTheConversation() async {
        let session = newSession()
        let task = await startCall(click, session, .ask)
        tool.resolve(try! XCTUnwrap(cards().first), with: .always)
        let first = await task.value
        XCTAssertTrue(first.success)
        tool.turnEnded(session)
        let next = await call(click, session, .ask)
        XCTAssertTrue(next.success)
        XCTAssertEqual(fake.batches.count, 2)
        XCTAssertEqual(cards().count, 1)
    }

    func testFullAccessWithMissingAccessStillAsks() async {
        tool.missingAccess = { "Accessibility is off" }
        let session = newSession()
        let task = await startCall(click, session, .fullAccess)
        XCTAssertEqual(cards().count, 1)
        tool.missingAccess = { nil }
        tool.resolve(try! XCTUnwrap(cards().first), with: .once)
        let result = await task.value
        XCTAssertTrue(result.success)
        XCTAssertEqual(fake.batches.count, 1)
    }

    func testApprovedButStillMissingAccessFails() async {
        tool.missingAccess = { "Accessibility is off" }
        let session = newSession()
        let task = await startCall(click, session, .ask)
        tool.resolve(try! XCTUnwrap(cards().first), with: .always)
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("Accessibility is off"))
        XCTAssertTrue(fake.batches.isEmpty)
    }

    func testConcurrentCallsShareOneCard() async {
        let session = newSession()
        let first = await startCall(click, session, .ask)
        let second = Task { await self.call(self.click, session, .ask) }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cards().count, 1)
        tool.resolve(try! XCTUnwrap(cards().first), with: .once)
        let results = [await first.value, await second.value]
        XCTAssertTrue(results.allSatisfy(\.success))
        XCTAssertEqual(fake.batches.count, 2)
        XCTAssertEqual(cards().count, 1)
    }

    func testTurnEndedDeclinesWaitingCard() async {
        let session = newSession()
        let task = await startCall(click, session, .ask)
        XCTAssertFalse(tool.pendingPermissions(for: session).isEmpty)
        tool.turnEnded(session)
        XCTAssertTrue(tool.pendingPermissions(for: session).isEmpty)
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("declined"))
        XCTAssertTrue(fake.batches.isEmpty)
    }

    func testCardDescribesTheRequest() async {
        let session = newSession()
        let task = await startCall(click, session, .ask)
        let card = try! XCTUnwrap(cards().first)
        XCTAssertEqual(card.permission, ComputerTool.permissionKind)
        XCTAssertEqual(card.sessionID, session)
        XCTAssertFalse(card.patterns.first?.isEmpty ?? true)
        tool.resolve(card, with: .reject)
        _ = await task.value
    }
}
