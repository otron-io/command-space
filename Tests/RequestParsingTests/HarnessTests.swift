import XCTest
@testable import CommandSpace

final class HarnessTests: XCTestCase {
    func testContextIsHiddenFromHistory() {
        let wrapped = SpaceWorkspace.wrap(context: "[What the user was looking at]\nApp: Finder", around: "move these to Documents")
        XCTAssertTrue(wrapped.hasPrefix(SpaceWorkspace.contextOpen))
        XCTAssertEqual(SpaceWorkspace.stripContext(wrapped), "move these to Documents")
        XCTAssertEqual(SpaceWorkspace.stripContext("plain request"), "plain request")
    }

    func testCodexCommandsLoseTheShellWrapper() {
        XCTAssertEqual(CodexBackend.shortCommand("/bin/zsh -lc date"), "date")
        XCTAssertEqual(CodexBackend.shortCommand("/bin/zsh -lc 'open -a Safari'"), "open -a Safari")
        XCTAssertEqual(CodexBackend.shortCommand("ls -la"), "ls -la")
    }

    func testClaudeModelNames() {
        XCTAssertEqual(ClaudeBackend.prettyModel("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeBackend.prettyModel("claude-haiku-5-5-20261001"), "Haiku 5.5")
        XCTAssertEqual(ClaudeBackend.prettyModel("sonnet"), "Sonnet")
    }

    func testClaudeToolNames() {
        XCTAssertEqual(ClaudeSession.toolName("Bash"), "bash")
        XCTAssertEqual(ClaudeSession.toolName("MultiEdit"), "edit")
        XCTAssertEqual(ClaudeSession.toolName("mcp__linear__list_issues"), "linear.list_issues")
    }

    /// A Claude Code session file: context hidden, reminders and tool results not shown as speech,
    /// failed tools marked, subagent (sidechain) entries skipped.
    func testClaudeTranscript() throws {
        let lines: [[String: Any]] = [
            ["type": "queue-operation", "operation": "enqueue"],
            ["type": "user", "uuid": "u1", "message": ["role": "user",
                "content": SpaceWorkspace.wrap(context: "App: Finder", around: "what's in Downloads?")]],
            ["type": "user", "uuid": "m1", "isMeta": true, "message": ["role": "user", "content": "<system-reminder>x</system-reminder>"]],
            ["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": ""],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls ~/Downloads"]],
            ]]],
            ["type": "user", "uuid": "r1", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "ls: permission denied", "is_error": true],
            ]]],
            ["type": "assistant", "uuid": "s1", "isSidechain": true, "message": ["role": "assistant", "content": [
                ["type": "text", "text": "subagent chatter"],
            ]]],
            ["type": "assistant", "uuid": "a2", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "I couldn't read Downloads."],
            ]]],
            ["type": "ai-title", "aiTitle": "Downloads contents"],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let body = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let items = try XCTUnwrap(ClaudeBackend.transcript(of: url))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .user)
        XCTAssertEqual(items[0].text, "what's in Downloads?")
        XCTAssertEqual(items[1].kind, .tool(name: "bash", status: "error"))
        XCTAssertEqual(items[1].text, "ls ~/Downloads\nls: permission denied")
        XCTAssertEqual(items[2].kind, .assistant)
        XCTAssertEqual(items[2].text, "I couldn't read Downloads.")
    }
}
