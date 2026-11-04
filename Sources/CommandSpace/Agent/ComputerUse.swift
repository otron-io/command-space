//
//  ComputerUse.swift
//  Command Space
//
//  System One computer use: runs "open notes and create a new note and add text saying
//  Hello world" one step at a time, on this Mac, without System Two. Each step is either
//  plain code (open an app, type, press a key, wait) or one Snap 1 choice between the
//  front app's real menu commands and on-screen controls. Anything it can't do confidently,
//  or anything that sends, deletes or buys, is handed to System Two with what's done so far.
//

import AppKit
import ApplicationServices
import Defaults
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.commandspace", category: "computer-use")

struct StepOutcome {
    var done: [String] = []
    /// Steps left for System Two (empty when everything ran).
    var remaining: [String] = []
    var reason: String?

    var finished: Bool { remaining.isEmpty }
}

@MainActor
final class StepRunner {
    static let shared = StepRunner()

    private var running = false
    var isRunning: Bool { running }
    private init() {}

    /// Whether System One should take this request as computer-use steps.
    static func shouldRun(_ steps: [String]) -> Bool {
        if steps.count > 1 { return true }
        guard let step = steps.first, let local = StepParsing.local(step) else { return false }
        switch local {
        case .type, .press: return true
        case .open, .wait: return false  // single "open X" is already an instant action
        }
    }

    func run(_ steps: [String], progress: @escaping (String) -> Void = { _ in }) async -> StepOutcome {
        // One chain at a time (continuous voice can queue the next command while one runs).
        while running { try? await Task.sleep(for: .milliseconds(50)) }
        running = true
        defer { running = false }

        var outcome = StepOutcome()
        await leaveCommandSpace()
        for (index, step) in steps.enumerated() {
            let prefix = steps.count > 1 ? "\(index + 1)/\(steps.count) · " : ""
            if StepParsing.isRisky(step) {
                outcome.remaining = Array(steps[index...])
                outcome.reason = "“\(step)” needs your approval"
                break
            }
            guard let label = await perform(step) else {
                outcome.remaining = Array(steps[index...])
                outcome.reason = "System One couldn’t do “\(step)”"
                log.notice("step \(index + 1) failed")
                break
            }
            log.notice("step \(index + 1) done: \(label, privacy: .private)")
            outcome.done.append(label)
            progress(prefix + label)
            // Let the app react (new window, focus moving) before the next step looks at it.
            try? await Task.sleep(for: .milliseconds(index == steps.count - 1 ? 0 : 350))
        }
        return outcome
    }

    // MARK: One step

    private func perform(_ step: String) async -> String? {
        if let local = StepParsing.local(step) {
            switch local {
            case .open(let name):
                if let app = Self.resolveApp(name) {
                    return await open(app) ? "Opened \(app.name)" : nil
                }
                // Not an app name ("open a new tab"): let the menus and controls handle it.
            case .type(let text):
                guard Self.frontmostIsOther else { return nil }
                await Keyboard.type(text)
                return "Typed “\(text.count > 40 ? String(text.prefix(40)) + "…" : text)”"
            case .press(let chord, let times):
                guard Self.frontmostIsOther else { return nil }
                for _ in 0..<times {
                    Keyboard.press(chord)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                return "Pressed \(chord.label)" + (times > 1 ? " ×\(times)" : "")
            case .wait(let seconds):
                try? await Task.sleep(for: .seconds(seconds))
                return "Waited \(Int(seconds.rounded()))s"
            }
        }
        guard DecisionEngine.shared.decisionsAvailable,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        // Fresh look at whatever app is in front now (it may have changed in the last step).
        ContextCapture.shared.begin(allowCopyFallback: false, captureImage: false)
        // A just-opened app's menus can take a moment to read; the decision needs them.
        _ = await ContextCapture.shared.menuItems(maxWait: 1.2)
        if let quick = await QuickActions.shared.tryHandle(step, useCapturedContext: true) {
            return quick.label
        }
        return await clickControl(for: step, in: front)
    }

    /// Snap 1 picks one of the front window's controls; System One presses it.
    private func clickControl(for step: String, in app: NSRunningApplication) async -> String? {
        let pid = app.processIdentifier
        var controls = await Task.detached { WindowControls.list(pid: pid) }.value
        // "Click the search field": text inputs, or a button that opens one (Notes' collapsed
        // search). Either way it only counts if a text field ends up with focus.
        let wantsField = step.range(of: #"\b(?:field|box|bar|input|text area)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        if wantsField {
            controls = controls.filter { $0.isTextInput || $0.role == "AXButton" }
        }
        guard !controls.isEmpty else { return nil }
        let ranked = RequestParsing.rankMenuItems(controls.map(\.label), for: step, limit: 150)
        var options = ranked.enumerated().map { ("c\($0.offset)", $0.element) }
        options.append(("none", "None of these controls"))
        let appName = app.localizedName ?? "the app"
        guard let result = await DecisionEngine.shared.decide(
            state: ["request": step, "app": appName],
            questions: [("control", .choice("Which control in \(appName)'s window does this step ask to click or use?", options))],
            fallback: .none,
            timeout: 1.5
        ), let id = result["control"]?.choice, id != "none", (result["control"]?.confidence ?? 0) >= 0.5,
           let index = Int(id.dropFirst()), ranked.indices.contains(index),
           let control = controls.first(where: { $0.label == ranked[index] }) else { return nil }
        log.notice("control: \(control.label, privacy: .public) @\(result["control"]?.confidence ?? 0)")
        let before = await Task.detached { WindowControls.focusedElement(pid: pid) }.value
        let pressed = await Task.detached { WindowControls.press(control) }.value
        if control.isTextInput || wantsField {
            // Typing goes wherever focus is, so a field that didn't take focus stops the chain.
            try? await Task.sleep(for: .milliseconds(200))
            let focusedField = await Task.detached { () -> Bool in
                if control.isTextInput { return WindowControls.isFocused(control) }
                guard let now = WindowControls.focusedElement(pid: pid) else { return false }
                return WindowControls.isTextInput(now.element) && !(before.map { CFEqual($0.element, now.element) } ?? false)
            }.value
            guard focusedField else {
                log.notice("no text field took focus")
                return nil
            }
        }
        return pressed ? "Clicked \(control.title)" : nil
    }

    // MARK: Apps

    private struct ResolvedApp {
        let name: String
        let url: URL
        let bundleID: String?
    }

    private static func resolveApp(_ name: String) -> ResolvedApp? {
        let query = name.lowercased().trimmingCharacters(in: .whitespaces)
        var best: (AppEntry, Double)?
        for app in AppIndex.shared.apps {
            let score = ([app.name] + app.aliases).map { FuzzyMatch.score(query, in: $0) }.max() ?? 0
            if score > (best?.1 ?? 0) { best = (app, score) }
        }
        // Only a confident name match: "open a new tab" must not launch some app called "Tab…".
        guard let (app, score) = best, score >= 0.9 else { return nil }
        return ResolvedApp(name: app.name, url: app.url, bundleID: app.bundleID)
    }

    private func open(_ app: ResolvedApp) async -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard (try? await NSWorkspace.shared.openApplication(at: app.url, configuration: config)) != nil else { return false }
        // Wait until it's in front with a window to work in.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier == app.bundleID || front.bundleURL == app.url {
                let pid = front.processIdentifier
                if await Task.detached(operation: { WindowControls.hasFocusedWindow(pid: pid) }).value { return true }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return NSWorkspace.shared.frontmostApplication?.bundleURL == app.url
    }

    private static var frontmostIsOther: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    /// Typed into the panel: put the user's app back in front before acting on it.
    private func leaveCommandSpace() async {
        guard NSApp.isActive || CommandPanelController.shared.isVisible else { return }
        let target = ContextCapture.shared.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        CommandPanelController.shared.hide()
        if let target { target.activate() } else { NSApp.hide(nil) }
        let deadline = Date().addingTimeInterval(1.5)
        while !Self.frontmostIsOther, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
    }
}

// MARK: - Window controls

struct WindowControl: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    let title: String
    var isTextInput: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) }
    /// What Snap 1 sees: "Button: New Note".
    var label: String { "\(WindowControls.roleName(role)): \(title)" }
}

enum WindowControls {
    private static let roles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
        "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXTab",
    ]

    static func roleName(_ role: String) -> String {
        switch role {
        case "AXButton": "Button"
        case "AXCheckBox": "Checkbox"
        case "AXRadioButton", "AXTab": "Tab"
        case "AXPopUpButton", "AXMenuButton": "Pop-up menu"
        case "AXLink": "Link"
        case "AXTextField", "AXComboBox": "Text field"
        case "AXSearchField": "Search field"
        case "AXTextArea": "Text area"
        case "AXDisclosureTriangle": "Disclosure"
        default: "Control"
        }
    }

    static func hasFocusedWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return (attribute(app, kAXFocusedWindowAttribute) as AXUIElement?) != nil
    }

    /// Enabled, labelled controls in the focused window (toolbar included), in reading order.
    static func list(pid: pid_t, limit: Int = 400) -> [WindowControl] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return [] }
        var found: [WindowControl] = []
        var seen = Set<String>()
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let started = Date()
        while !queue.isEmpty, visited < 4000, found.count < limit, Date().timeIntervalSince(started) < 1.2 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role: String = attribute(node, kAXRoleAttribute) ?? ""
            if roles.contains(role), (attribute(node, kAXEnabledAttribute) as Bool?) != false {
                var effectiveRole = role
                if (attribute(node, kAXSubroleAttribute) as String?) == "AXSearchField" { effectiveRole = "AXSearchField" }
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
                    .lazy.compactMap { attribute(node, $0) as String? }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                let fallback = effectiveRole == "AXSearchField" ? "Search" : nil
                if let title = title ?? fallback, title.count <= 80, !StepParsing.isRisky(title) {
                    let control = WindowControl(element: node, role: effectiveRole, title: title)
                    if seen.insert(control.label).inserted { found.append(control) }
                }
            }
            guard depth < 25 else { continue }
            let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
            queue += children.map { ($0, depth + 1) }
        }
        return found
    }

    static func press(_ control: WindowControl) -> Bool {
        if control.isTextInput {
            AXUIElementSetAttributeValue(control.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if isFocused(control) { return true }
            // Some fields (toolbar search) ignore AX focus; a real click works everywhere.
            return click(control)
        }
        if AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success { return true }
        return AXUIElementPerformAction(control.element, "AXPick" as CFString) == .success
    }

    struct Focused: @unchecked Sendable { let element: AXUIElement }

    static func focusedElement(pid: pid_t) -> Focused? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return (attribute(app, kAXFocusedUIElementAttribute) as AXUIElement?).map(Focused.init)
    }

    static func isTextInput(_ element: AXUIElement) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(attribute(element, kAXRoleAttribute) as String? ?? "")
    }

    static func isFocused(_ control: WindowControl) -> Bool {
        (attribute(control.element, kAXFocusedAttribute) as Bool?) == true
    }

    /// Clicks the middle of the control with the mouse, then puts the pointer back.
    static func click(_ control: WindowControl) -> Bool {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(control.element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(control.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return false }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return false }
        let target = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let previous = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let previous {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: previous, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == [AXUIElement].self {
            return (value as? [AnyObject])?.compactMap { obj -> AXUIElement? in
                CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
            } as? T
        }
        return value as? T
    }
}

// MARK: - Keyboard

enum Keyboard {
    /// Types text into whatever has focus, as keystrokes (works in every app, unlike AX values).
    static func type(_ text: String) async {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.flags = []
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event.post(tap: .cghidEventTap)
                }
                start += 16
                try? await Task.sleep(for: .milliseconds(8))
            }
            if index < lines.count - 1 {
                press(StepParsing.KeyChord(keyCode: 36, flags: [], label: "⏎"))
            }
        }
    }

    static func press(_ chord: StepParsing.KeyChord) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: down) else { continue }
            event.flags = chord.flags
            event.post(tap: .cghidEventTap)
        }
    }
}
