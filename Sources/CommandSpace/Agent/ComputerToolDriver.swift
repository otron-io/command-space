//
//  ComputerToolDriver.swift
//  Command Space
//
//  The hands and eyes of the System Two `computer` tool: performs a batch of actions with
//  the mouse and keyboard (CGEvents), then takes a screenshot of the display the user is
//  working on with ScreenCaptureKit. Also owns the two macOS permissions this needs.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "io.otron.commandspace", category: "computer-tool")

struct ComputerResult {
    var success: Bool
    var text: String
    var image: ScreenImage?
}

@MainActor
protocol ComputerDriver: AnyObject {
    /// Runs the actions in order (stopping early if `shouldStop()` turns true), then returns what the screen looks like.
    func perform(_ actions: [ComputerAction], shouldStop: @escaping () -> Bool) async -> ComputerResult
}

/// The two macOS permissions computer use needs.
enum ComputerAccess {
    enum Requirement: String, CaseIterable, Identifiable {
        case accessibility, screenRecording

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen Recording"
            }
        }

        var reason: String {
            switch self {
            case .accessibility: "Lets Space click and type for you."
            case .screenRecording: "Lets Space see the screen it's working on."
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    static func isGranted(_ requirement: Requirement) -> Bool {
        #if DEBUG
        // `defaults write CommandSpace debugDenyComputerAccess screenRecording` shows the
        // not-yet-granted states (card checklist, Settings, command line) without revoking anything.
        if UserDefaults.standard.string(forKey: "debugDenyComputerAccess")?.contains(requirement.rawValue) == true { return false }
        #endif
        switch requirement {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    static var missing: [Requirement] { Requirement.allCases.filter { !isGranted($0) } }
    static var ready: Bool { missing.isEmpty }

    /// Shows the system prompt where macOS has one, and opens the right System Settings pane.
    @MainActor static func request(_ requirement: Requirement) {
        switch requirement {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(requirement.settingsURL)
    }

    /// A sentence naming what's missing and where to turn it on, or nil when ready.
    static var missingExplanation: String? {
        let missing = missing
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.title).joined(separator: " and ")
        var text = "Command Space needs \(names) permission to control the computer. Ask the user to turn it on in System Settings → Privacy & Security."
        if missing.contains(.screenRecording) {
            text += " Screen Recording may need Command Space to be reopened before it takes effect."
        }
        return text
    }
}

private struct ActionFailure: Error {
    let message: String
}

@MainActor
final class MacComputer: ComputerDriver {
    static let shared = MacComputer()
    /// Stamped on every event we post (CGEventField.eventSourceUserData) so our own key presses aren't mistaken for the user's.
    nonisolated static let eventMarker: Int64 = 0x5350_4143

    private var geometry: ScreenGeometry?
    /// The app that was in front when the model last looked, or that our own last action put there.
    private var expectedFront: pid_t?
    private let source = CGEventSource(stateID: .hidSystemState)
    private init() {}

    // MARK: Batch

    func perform(_ actions: [ComputerAction], shouldStop: @escaping () -> Bool) async -> ComputerResult {
        if let missing = ComputerAccess.missingExplanation {
            return ComputerResult(success: false, text: missing, image: nil)
        }
        if Self.screenIsLocked {
            return ComputerResult(success: false, text: "The Mac's screen is locked, so there is nothing to see or control. Stop, and tell the user to unlock it and ask again.", image: nil)
        }

        var done: [String] = []
        var failure: String?
        var changedScreen = false
        for (index, action) in actions.enumerated() {
            if shouldStop() { return stopped(after: done) }
            log.notice("action \(index + 1)/\(actions.count): \(action.summary, privacy: .private)")
            do {
                try await execute(action, shouldStop: shouldStop)
                if shouldStop() { return stopped(after: done) }
                done.append(action.summary)
                if !action.isReadOnly { changedScreen = true }
            } catch let error as ActionFailure {
                failure = "Stopped at actions[\(index)] (\(action.summary)): \(error.message)"
                changedScreen = changedScreen || !action.isReadOnly
                break
            } catch {
                failure = "Stopped at actions[\(index)] (\(action.summary)): \(error.localizedDescription)"
                break
            }
        }
        if shouldStop() { return stopped(after: done) }

        // Let the app react before looking.
        if changedScreen { try? await Task.sleep(for: .milliseconds(600)) }
        if shouldStop() { return stopped(after: done) }

        var lines = [done.isEmpty ? "Looked at the screen." : "Done: " + done.joined(separator: "; ")]
        if let failure { lines[0] = done.isEmpty ? "Nothing was done." : lines[0]; lines.append(failure) }
        var image: ScreenImage?
        do {
            let shot = try await captureScreen(shouldStop: shouldStop)
            if shouldStop() { return stopped(after: done) }
            image = shot.image
            lines.append("Screenshot: \(Int(shot.size.width))x\(Int(shot.size.height)) px. Coordinates for actions are pixels in this screenshot, origin top-left.")
        } catch {
            if shouldStop() { return stopped(after: done) }
            log.error("screenshot failed: \(error.localizedDescription, privacy: .public)")
            lines.append("The screenshot failed: \(error.localizedDescription)")
            failure = failure ?? "The screenshot failed."
        }
        lines.append(frontAppLine())
        return ComputerResult(success: failure == nil, text: lines.joined(separator: "\n"), image: image)
    }

    /// Behind the lock screen clicks and keys would go to the login window; never try.
    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private func stopped(after done: [String]) -> ComputerResult {
        var text = "Computer control was stopped. Do not continue the task."
        if !done.isEmpty { text += "\nDone before stopping: " + done.joined(separator: "; ") }
        return ComputerResult(success: false, text: text, image: nil)
    }

    private func frontAppLine() -> String {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        var line = "Front app: \(name)."
        if let location = CGEvent(source: nil)?.location {
            let pixel = currentGeometry().pixel(for: location)
            line += " Pointer at (\(Int(pixel.x.rounded())), \(Int(pixel.y.rounded())))."
        }
        return line
    }

    // MARK: Actions

    private func execute(_ action: ComputerAction, shouldStop: @escaping () -> Bool) async throws {
        switch action {
        case .screenshot:
            break  // always captured at the end
        case .click(let x, let y, let button, let count):
            await click(currentGeometry().point(x: x, y: y), button: button, count: count, shouldStop: shouldStop)
            if !shouldStop() { await noteFrontApp() }
        case .move(let x, let y):
            postMouse(.mouseMoved, at: currentGeometry().point(x: x, y: y), button: .left)
        case .drag(let path):
            let geometry = currentGeometry()
            await drag(path.map { geometry.point(x: $0.x, y: $0.y) }, shouldStop: shouldStop)
            if !shouldStop() { await noteFrontApp() }
        case .scroll(let x, let y, let dx, let dy):
            await scroll(at: currentGeometry().point(x: x, y: y), dx: dx, dy: dy, shouldStop: shouldStop)
        case .type(let text):
            try checkFrontApp()
            if Self.focusedFieldIsSecure() {
                throw ActionFailure(message: "The focused field is a password field. Passwords must be typed by the user; ask them to do it.")
            }
            await type(text, shouldStop: shouldStop)
        case .keypress(let keys):
            guard let strokes = ComputerActions.keyStrokes(for: keys) else {
                throw ActionFailure(message: "Unknown key in [\(keys.joined(separator: ", "))]. Use names like CMD, SHIFT, ENTER, TAB, ESC, UP, F5 or single letters.")
            }
            try checkFrontApp()
            for stroke in strokes {
                if shouldStop() { return }
                postKey(stroke.keyCode, down: true, flags: stroke.flags)
                try? await Task.sleep(for: .milliseconds(50))
                postKey(stroke.keyCode, down: false, flags: stroke.flags)
                if shouldStop() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        case .wait(let seconds):
            var remaining = seconds
            while remaining > 0, !shouldStop() {
                let slice = min(remaining, 0.1)
                try? await Task.sleep(for: .seconds(slice))
                remaining -= slice
            }
        case .openApp(let name):
            try await openApp(named: name, shouldStop: shouldStop)
            if !shouldStop() { await noteFrontApp() }
        }
        // A shortcut such as ⌘⇥ may switch apps on purpose.
        if case .keypress = action, !shouldStop() { await noteFrontApp() }
    }

    // MARK: Whose keys are these

    /// Keys go to whatever has focus. If the user switched apps since the model last looked,
    /// typing would land in their window (a chat box, a terminal), so the batch stops instead.
    private func checkFrontApp() throws {
        guard let expected = expectedFront, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != expected else { return }
        throw ActionFailure(message: "The app in front changed to \(front.localizedName ?? "another app") since you last looked, so nothing was typed: the user may be using the computer. Take a screenshot and check before continuing.")
    }

    /// After an action of ours that can change the front app, that app is the one keys are meant for.
    private func noteFrontApp() async {
        try? await Task.sleep(for: .milliseconds(150))
        expectedFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: Mouse

    private func stamp(_ event: CGEvent?) -> CGEvent? {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        return event
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64? = nil) {
        guard let event = stamp(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)) else { return }
        if let clickState { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        event.post(tap: .cghidEventTap)
    }

    private func click(_ point: CGPoint, button: ComputerAction.Button, count: Int, shouldStop: () -> Bool) async {
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        postMouse(.mouseMoved, at: point, button: .left)
        try? await Task.sleep(for: .milliseconds(40))
        for n in 1...max(1, min(count, 3)) {
            if shouldStop() { return }
            postMouse(down, at: point, button: cgButton, clickState: Int64(n))
            try? await Task.sleep(for: .milliseconds(30))
            postMouse(up, at: point, button: cgButton, clickState: Int64(n))
            if shouldStop() { return }
            if n < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
    }

    private func drag(_ path: [CGPoint], shouldStop: () -> Bool) async {
        guard let first = path.first else { return }
        postMouse(.mouseMoved, at: first, button: .left)
        try? await Task.sleep(for: .milliseconds(40))
        if shouldStop() { return }
        postMouse(.leftMouseDown, at: first, button: .left, clickState: 1)
        var position = first
        defer { postMouse(.leftMouseUp, at: position, button: .left, clickState: 1) }
        try? await Task.sleep(for: .milliseconds(40))
        var from = first
        for target in path.dropFirst() {
            let distance = hypot(target.x - from.x, target.y - from.y)
            let steps = max(1, Int((distance / 20).rounded(.up)))
            for step in 1...steps {
                if shouldStop() { return }
                let t = CGFloat(step) / CGFloat(steps)
                position = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
                postMouse(.leftMouseDragged, at: position, button: .left)
                try? await Task.sleep(for: .milliseconds(8))
            }
            from = target
        }
        if !shouldStop() { try? await Task.sleep(for: .milliseconds(40)) }
    }

    private func scroll(at point: CGPoint, dx: Double, dy: Double, shouldStop: () -> Bool) async {
        postMouse(.mouseMoved, at: point, button: .left)
        try? await Task.sleep(for: .milliseconds(40))
        if shouldStop() { return }
        let chunks = max(1, Int((max(abs(dx), abs(dy)) / 400).rounded(.up)))
        var sentX = 0.0
        var sentY = 0.0
        for i in 1...chunks {
            if shouldStop() { return }
            // Positive dy scrolls the content down, which is a negative wheel value.
            let targetX = dx * Double(i) / Double(chunks)
            let targetY = dy * Double(i) / Double(chunks)
            let stepX = Int32((targetX - sentX).rounded())
            let stepY = Int32((targetY - sentY).rounded())
            sentX += Double(stepX)
            sentY += Double(stepY)
            if stepX != 0 || stepY != 0,
               let event = stamp(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -stepY, wheel2: -stepX, wheel3: 0)) {
                event.post(tap: .cghidEventTap)
            }
            if i < chunks { try? await Task.sleep(for: .milliseconds(15)) }
        }
    }

    // MARK: Keyboard

    private func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = stamp(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String, shouldStop: () -> Bool) async {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            // One key event per character: apps that treat keys as commands (Calculator) only
            // read the first character of an event, so "12*7" in one event would arrive as "1".
            for character in line {
                if shouldStop() { return }
                let key = String(character)
                let code = ComputerActions.keyStrokes(for: [key])?.first.flatMap { $0.flags.isEmpty ? $0.keyCode : nil } ?? 0
                await typeUnits(Array(key.utf16), keyCode: code)
            }
            if index < lines.count - 1 {
                if shouldStop() { return }
                postKey(36, down: true, flags: [])
                postKey(36, down: false, flags: [])
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// The unicode string decides what is typed (any keyboard layout); the key code is for apps that look at keys.
    private func typeUnits(_ units: [UInt16], keyCode: CGKeyCode) async {
        for down in [true, false] {
            guard let event = stamp(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(6))
    }

    private static func focusedFieldIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == "AXSecureTextField"
    }

    // MARK: Apps

    private func openApp(named name: String, shouldStop: () -> Bool) async throws {
        let query = name.lowercased().trimmingCharacters(in: .whitespaces)
        // The index loads asynchronously and can still be empty right after a command-line start.
        for _ in 0..<30 where AppIndex.shared.apps.isEmpty {
            if shouldStop() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if shouldStop() { return }
        var best: (AppEntry, Double)?
        for app in AppIndex.shared.apps {
            let score = ([app.name] + app.aliases).map { FuzzyMatch.score(query, in: $0) }.max() ?? 0
            if score > (best?.1 ?? 0) { best = (app, score) }
        }
        guard let (app, score) = best, score >= 0.9 else {
            throw ActionFailure(message: "No app named “\(name)” found")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
        } catch {
            throw ActionFailure(message: "Couldn't open \(app.name): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(5)
        while !shouldStop(), Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleURL == app.url || (app.bundleID != nil && front.bundleIdentifier == app.bundleID) { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
        if !shouldStop() { throw ActionFailure(message: "\(app.name) was opened but did not come to the front") }
    }

    // MARK: Screen

    /// The display the user's front window is on (the main display when unknown).
    private func targetDisplayID() -> CGDirectDisplayID {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            if let info = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            }),
               let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict) {
                var display = CGDirectDisplayID()
                var count: UInt32 = 0
                if CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &display, &count) == .success, count > 0 {
                    return display
                }
            }
        }
        return CGMainDisplayID()
    }

    private func geometry(for displayID: CGDirectDisplayID) -> ScreenGeometry {
        let frame = CGDisplayBounds(displayID)
        return ScreenGeometry(frame: frame, imageSize: ScreenGeometry.imageSize(for: frame.size))
    }

    /// The latest screenshot's geometry, or the target display's when nothing has been captured yet.
    private func currentGeometry() -> ScreenGeometry {
        if let geometry { return geometry }
        let fresh = geometry(for: targetDisplayID())
        geometry = fresh
        return fresh
    }

    private func captureScreen(shouldStop: () -> Bool) async throws -> (image: ScreenImage, size: CGSize) {
        let displayID = targetDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if shouldStop() { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ActionFailure(message: "No display to capture")
        }
        let next = geometry(for: display.displayID)
        // Our own panel and pill must never appear in what the model sees.
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(next.imageSize.width)
        config.height = Int(next.imageSize.height)
        config.showsCursor = true
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if shouldStop() { throw CancellationError() }
        guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ActionFailure(message: "Couldn't encode the screenshot")
        }
        geometry = next
        expectedFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return (ScreenImage(data: data, mimeType: "image/jpeg"), next.imageSize)
    }
}
