import AppKit
import XCTest
@testable import CommandSpace

final class ClipboardTests: XCTestCase {
    private func png(width: Int = 32, height: Int = 24) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
    }

    func testImagesAreBoundedAndReencoded() throws {
        let image = try ClipboardImages.prepare(png(width: 3200, height: 80))
        XCTAssertEqual(image.mimeType, "image/png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.data))
        XCTAssertEqual(bitmap.pixelsWide, 1800)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 1800)
        XCTAssertLessThanOrEqual(image.data.count, 4_000_000)
        XCTAssertThrowsError(try ClipboardImages.prepare(Data("not an image".utf8)))
    }

    @MainActor func testTextPasteReplacesNativeSelection() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Space", forType: .string)
        XCTAssertTrue(try ClipboardImages.read(from: board).isEmpty)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        editor.string = "Hello world"
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        XCTAssertTrue(ClipboardImages.pasteText(from: board, into: editor))
        XCTAssertEqual(editor.string, "Hello Space")
    }

    @MainActor func testCommandVPastesIntoTheFieldAndRoutesImages() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        editor.string = "old text"
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        board.setString("new", forType: .string)
        let model = CommandSpaceModel()
        XCTAssertTrue(model.handleKey(event, pasteboard: board, editor: editor))
        XCTAssertEqual(editor.string, "new text")
        board.clearContents()
        board.setData(try png(), forType: .png)
        XCTAssertTrue(model.handleKey(event, pasteboard: board, editor: editor))
        XCTAssertEqual(model.mode, .agent)
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(editor.string, "new text")
    }

    @MainActor func testPastingImageSwitchesToSystemTwoWithoutSending() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try png(), forType: .png)
        let model = CommandSpaceModel()
        model.query = "Explain this"
        XCTAssertTrue(model.paste(from: board))
        XCTAssertEqual(model.mode, .agent)
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(model.query, "Explain this")
        XCTAssertNil(model.pasteError)
        model.reset()
        XCTAssertTrue(model.attachments.isEmpty)
    }

    @MainActor func testLimitAndBadImagesLeaveExistingAttachmentsIntact() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try png(), forType: .png)
        let model = CommandSpaceModel()
        for _ in 0..<4 { XCTAssertTrue(model.paste(from: board)) }
        XCTAssertEqual(model.attachments.count, 4)
        XCTAssertTrue(model.paste(from: board))
        XCTAssertEqual(model.attachments.count, 4)
        XCTAssertNotNil(model.pasteError)
        board.clearContents()
        board.setData(Data([0, 1, 2]), forType: .png)
        XCTAssertTrue(model.paste(from: board))
        XCTAssertEqual(model.attachments.count, 4)
        XCTAssertNotNil(model.pasteError)
    }

    @MainActor func testConversationWindowCanAttachImagesAndClearsThemOnThreadChange() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try png(), forType: .png)
        let controller = ThreadWindowController.shared
        controller.select(nil)
        controller.draft = "Explain this"
        XCTAssertTrue(controller.paste(from: board))
        XCTAssertEqual(controller.attachments.count, 1)
        XCTAssertEqual(controller.draft, "Explain this")
        XCTAssertNil(controller.thread)
        controller.select(nil)
        XCTAssertTrue(controller.attachments.isEmpty)
        XCTAssertTrue(controller.draft.isEmpty)
    }

    func testImageOnlyRequestAndTextArePreserved() {
        let image = ScreenImage(data: Data([1]), mimeType: "image/png")
        XCTAssertEqual(ClipboardImages.request(" ", images: [image]), "Describe this image.")
        XCTAssertEqual(ClipboardImages.request("", images: [image, image]), "Describe these images.")
        XCTAssertEqual(ClipboardImages.request("  What is this?  ", images: [image]), "What is this?")
        XCTAssertEqual(ClipboardImages.request("", images: []), "")
    }

    func testEveryHarnessReceivesEveryExplicitImage() {
        let image = ScreenImage(data: Data([1, 2]), mimeType: "image/png")
        let context = AgentRequestContext("Pasted images", attachments: [image, image])
        let codex = AgentInput.codex("Compare these", context: context, planning: false)
        XCTAssertEqual(codex.filter { $0["type"] as? String == "image" }.count, 2)
        XCTAssertEqual(codex[1]["url"] as? String, image.dataURL)
        let claude = AgentInput.claude("Compare these", context: context)
        XCTAssertEqual(claude.filter { $0["type"] as? String == "image" }.count, 2)
        let opencode = AgentInput.opencode("Compare these", context: context)
        XCTAssertEqual(opencode.filter { $0["type"] as? String == "file" }.count, 2)
        XCTAssertEqual(opencode.last?["filename"] as? String, "image-2.png")
        XCTAssertEqual(AgentRequestContext("Screen plus paste", image: image, attachments: [image]).images.count, 2)
    }

    @MainActor func testEditMenuSuppliesStandardShortcuts() {
        _ = NSApplication.shared
        AppMenus.install()
        let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu
        XCTAssertEqual(edit?.items.first(where: { $0.title == "Paste" })?.keyEquivalent, "v")
        XCTAssertEqual(edit?.items.first(where: { $0.title == "Select All" })?.keyEquivalent, "a")
        XCTAssertEqual(edit?.items.first(where: { $0.title == "Undo" })?.keyEquivalent, "z")
    }
}
