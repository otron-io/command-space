import AppKit
import Defaults
import ScreenCaptureKit

extension Defaults.Keys {
    static let screenIntelligence = Key<Bool>("screenIntelligence", default: true)
    static let screenImages = Key<Bool>("screenImages", default: true)
}

/// Captured images live in memory, not screenshot files. The harness may retain the sent image in its history.
struct ScreenImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

struct AgentRequestContext: Equatable, Sendable {
    let text: String
    var image: ScreenImage?
    /// A truthful text-only version, when the source also supplied readable contents.
    var textOnlyFallback: String?

    init(_ text: String, image: ScreenImage? = nil, textOnlyFallback: String? = nil) {
        self.text = text
        self.image = image
        self.textOnlyFallback = textOnlyFallback
    }
}

/// Centralized wire formats, so the three harnesses get the same visible request and image.
enum AgentInput {
    static func codex(_ text: String, context: AgentRequestContext?, planning: Bool) -> [[String: Any]] {
        let hidden = [planning ? SpaceWorkspace.planInstruction : nil, context?.text].compactMap { $0 }
        let message = hidden.isEmpty ? text : SpaceWorkspace.wrap(context: hidden.joined(separator: "\n\n"), around: text)
        var input: [[String: Any]] = [["type": "text", "text": message]]
        if let image = context?.image { input.append(["type": "image", "url": image.dataURL]) }
        return input
    }

    static func claude(_ text: String, context: AgentRequestContext?) -> [[String: Any]] {
        let message = context.map { SpaceWorkspace.wrap(context: $0.text, around: text) } ?? text
        var content: [[String: Any]] = [["type": "text", "text": message]]
        if let image = context?.image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType,
                                                          "data": image.data.base64EncodedString()]])
        }
        return content
    }

    static func opencodeSupportsImages(_ providers: [String: Any], model: String) -> Bool? {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let provider = (providers["all"] as? [[String: Any]])?.first(where: { $0["id"] as? String == parts[0] }),
              let entry = (provider["models"] as? [String: [String: Any]])?[parts[1]],
              let capabilities = entry["capabilities"] as? [String: Any],
              let input = capabilities["input"] as? [String: Any] else { return nil }
        return input["image"] as? Bool
    }

    static func opencode(_ text: String, context: AgentRequestContext?) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        if let context { parts.append(["type": "text", "text": context.text, "synthetic": true]) }
        parts.append(["type": "text", "text": text])
        if let image = context?.image {
            parts.append(["type": "file", "mime": image.mimeType,
                          "filename": image.mimeType == "image/png" ? "screen-context.png" : "screen-context.jpg", "url": image.dataURL])
        }
        return parts
    }
}

enum ScreenSnapshot {
    /// Pick the frontmost normal window now, before the launcher appears or the user changes tabs.
    static func windowID(for pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Only called from an explicit user click. Opening the launcher never triggers a permission dialog.
    @MainActor static func requestAccess() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    static func capture(windowID: CGWindowID) async throws -> ScreenImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Preserve legibility without sending full Retina resolution or unbounded images.
        let scale = min(2.0, 1800 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.captureResolution = .nominal
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let bytes = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              bytes.count <= 4_000_000 else { return nil }
        return ScreenImage(data: bytes, mimeType: "image/jpeg")
    }
}
