import AppKit
import Defaults
import SwiftUI

/// Always discoverable in the bar; the context itself only travels with a relevant sent question.
struct ScreenContextControl: View {
    @ObservedObject private var capture = ContextCapture.shared
    @Default(.screenIntelligence) private var enabled
    @Default(.screenImages) private var imagesEnabled

    var body: some View {
        Menu {
            if let screen = capture.captured, enabled {
                Text(screen.summary)
                if let text = screen.selectedText { Text("“\(text.prefix(100))”") }
                if imagesEnabled, screen.image != nil { Text("Source window image available") }
                Divider()
                Button(capture.choice == .automatic ? "✓ Automatic for screen questions" : "Automatic for screen questions") { capture.choice = .automatic }
                Button(capture.choice == .include ? "✓ Attach to request" : "Attach to request") { capture.choice = .include }
                Button(capture.choice == .exclude ? "✓ Don’t share context" : "Don’t share context") { capture.choice = .exclude }
            } else {
                Text(enabled ? "No source app captured. Reopen ⌘Space from another app." : "Screen intelligence is off")
            }
            Divider()
            if !ScreenSnapshot.isAllowed {
                Button("Enable window images…") { ScreenSnapshot.requestAccess() }
            }
            Button("Screen intelligence settings…") { SettingsWindowController.shared.show(page: .agent) }
        } label: {
            Image(systemName: capture.choice == .exclude || !enabled ? "rectangle.slash" : "viewfinder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(capture.choice == .include ? Color.cyan : Color.white.opacity(0.55))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Screen intelligence: source captured at ⌘Space; shared only with screen questions or when attached")
        .accessibilityLabel("Screen intelligence")
    }
}

struct ScreenContextStrip: View {
    let query: String
    @ObservedObject private var capture = ContextCapture.shared
    @Default(.screenIntelligence) private var enabled
    @Default(.screenImages) private var imagesEnabled

    private var screen: ScreenContext? {
        guard enabled, capture.choice != .exclude, let screen = capture.captured,
              capture.choice == .include || screen.shouldAttach(to: query) else { return nil }
        var source = screen.focused(for: query, includeWholeWindow: capture.choice == .include)
        if !imagesEnabled { source.image = nil }
        return source
    }

    var body: some View {
        if let screen {
            HStack(spacing: 8) {
                if let image = screen.image, let preview = NSImage(data: image.data) {
                    Image(nsImage: preview).resizable().scaledToFit().frame(width: 36, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: screen.selectedText != nil ? "text.quote" : "macwindow")
                        .foregroundStyle(.cyan).frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(screen.summary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Text(screen.selectedText.map { String($0.prefix(90)).replacingOccurrences(of: "\n", with: " ") }
                         ?? screen.windowTitle ?? screen.pageURL ?? "Captured when you opened Command Space")
                        .font(.system(size: 10)).foregroundStyle(.gray).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(capture.isCapturing ? "Capturing…" : "Will share with Space")
                    .font(.system(size: 10)).foregroundStyle(.gray)
                Button { capture.choice = .exclude } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.gray)
                }.buttonStyle(.plain).help("Don’t attach screen context")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.cyan.opacity(0.045))
            .help(capture.imageError ?? "Selection, page/window text and the available source image are sent to the selected System Two harness with this request. They may be retained in its conversation history.")
        }
    }
}

struct ScreenIntelligenceSettings: View {
    @Default(.screenIntelligence) private var enabled
    @Default(.screenImages) private var imagesEnabled
    @State private var allowed = ScreenSnapshot.isAllowed

    var body: some View {
        Section {
            Defaults.Toggle("Use selected text and page/window context", key: .screenIntelligence)
            Defaults.Toggle("Include source window images", key: .screenImages).disabled(!enabled)
            HStack {
                Text(allowed ? "Screen Recording permission granted" : "Window images need Screen Recording permission")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(allowed ? "Open privacy settings…" : "Enable window images…") {
                    if allowed {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    } else { ScreenSnapshot.requestAccess() }
                    allowed = ScreenSnapshot.isAllowed
                }
            }
            Text("Open ⌘Space over an app, then ask “summarize this page”, “explain the highlighted text”, or “what’s in this image?”. The viewfinder in the bar lets you attach context explicitly or exclude it.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Screen intelligence") } footer: {
            Text("Captures the source window, not the launcher. Context stays on this Mac until you send a screen-related request; then it goes to your chosen System Two harness and may be stored in its history. Screenshots require permission; without it, text and page links still work. Nothing is sent to System One except context metadata. Reopen ⌘Space after granting permission.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            allowed = ScreenSnapshot.isAllowed
        }
        .onChange(of: enabled) { _, value in if !value { ContextCapture.shared.clear() } }
        .onChange(of: imagesEnabled) { _, value in if !value { ContextCapture.shared.discardImage() } }
    }
}
