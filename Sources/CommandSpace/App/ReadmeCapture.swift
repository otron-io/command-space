#if DEBUG
import AppKit
import Defaults
import SwiftUI

/// Reproducible documentation captures of production views. No desktop screenshots, keystroke
/// injection, commands, real conversations, or model requests. Only the selection is a fixture.
@MainActor enum ReadmeCapture {
    static func run(into directory: URL) {
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try renderLogo(into: directory)
                try await capturePanel(into: directory)
                print("README captures complete: \(directory.path)")
                exit(0)
            } catch {
                print("README capture failed: \(error)")
                exit(1)
            }
        }
    }

    private static func renderLogo(into directory: URL) throws {
        let frames = directory.appendingPathComponent("logo-frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let moods: [SpaceMood] = [.idle, .thinking, .working, .attention, .happy, .idle]
        for index in 0..<180 {
            let time = Double(index) / 20
            let segment = min(5, Int(time / 1.5))
            let local = time - Double(segment) * 1.5
            let blend = min(1, local / 0.25)
            let prior = moods[max(0, segment - 1)]
            let content = LogoFrame(mood: moods[segment], prior: prior, time: 2 + local,
                                    blend: blend * blend * (3 - 2 * blend))
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, .dark))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CaptureError.render }
            try data.write(to: frames.appendingPathComponent(String(format: "%04d.png", index)))
            if index == 0 { try data.write(to: directory.appendingPathComponent("command-space.png")) }
        }
    }

    private static func capturePanel(into directory: URL) async throws {
        let oldFiles = Defaults[.searchFiles], oldRanking = Defaults[.searchSnapRanking], oldContext = Defaults[.screenIntelligence]
        Defaults[.searchFiles] = false
        Defaults[.searchSnapRanking] = false
        Defaults[.screenIntelligence] = true
        defer {
            Defaults[.searchFiles] = oldFiles
            Defaults[.searchSnapRanking] = oldRanking
            Defaults[.screenIntelligence] = oldContext
            ContextCapture.shared.clear()
        }
        AppMenus.install()
        let state = CaptureState()
        let model = CommandSpaceModel()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: PanelScene(model: model, state: state))
        host.sizingOptions = []
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.center()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(5)
        while AppIndex.shared.apps.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard AppIndex.shared.apps.contains(where: { $0.name.lowercased() == "safari" }) else { throw CaptureError.apps }
        let frames = directory.appendingPathComponent("panel-frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        var frame = 0
        func record(_ count: Int) async throws {
            for _ in 0..<count {
                try await Task.sleep(for: .milliseconds(65))
                try save(host, to: frames.appendingPathComponent(String(format: "%04d.png", frame)))
                frame += 1
            }
        }
        func scene(_ name: String, query: String, filename: String) async throws {
            state.label = name
            model.mode = .search
            model.query = query
            if !model.isPresented { model.present() }
            try await record(25)
            try save(host, to: directory.appendingPathComponent(filename + ".png"))
            print("Captured \(filename): \(model.selectedResult?.title ?? "none")")
        }
        state.label = "ONE SHORTCUT. YOUR WHOLE MAC."
        model.present()
        try await record(12)
        try await scene("FIND YOUR APPS", query: "safari", filename: "app-search")
        try await scene("CONVERSIONS. INSTANT. LOCAL.", query: "10 km to miles", filename: "conversions")
        try await scene("A CALCULATOR, WITHOUT THE APP", query: "15% of 80", filename: "calculator")
        try await scene("SEE THE ACTION BEFORE YOU RUN IT", query: "set volume to 50", filename: "instant-actions")
        var source = ScreenContext(app: "Example article", bundleID: nil)
        source.windowTitle = "A short guide to solar energy"
        source.selectedText = "Photovoltaic cells convert light into electricity using semiconductor materials."
        ContextCapture.shared.setPreview(source)
        try await scene("ASK ABOUT WHAT YOU’RE LOOKING AT", query: "Explain the highlighted text", filename: "screen-intelligence")
        ContextCapture.shared.clear()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = try Data(contentsOf: directory.appendingPathComponent("command-space.png"))
        board.setData(image, forType: .png)
        model.query = "What’s in this image?"
        guard model.paste(from: board), model.attachments.count == 1, model.mode == .agent else { throw CaptureError.paste }
        state.label = "PASTE AN IMAGE. ASK SPACE."
        try await record(25)
        try save(host, to: directory.appendingPathComponent("image-paste.png"))
        model.attachments = []
        model.mode = .search
        model.query = ""
        state.label = "RIGHT WHERE YOU NEED IT."
        try await record(12)
        print("Recorded \(frame) native-view frames at ~15 fps; no actions were executed.")
    }

    private static func save(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.render }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage,
              let context = CGContext(data: nil, width: 960, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 960, height: 720))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { throw CaptureError.render }
        try data.write(to: url)
    }

    private enum CaptureError: Error { case render, apps, paste }
    private final class CaptureState: ObservableObject { @Published var label = "" }

    private struct PanelScene: View {
        @ObservedObject var model: CommandSpaceModel
        @ObservedObject var state: CaptureState
        var body: some View {
            ZStack(alignment: .top) {
                Color(red: 0.065, green: 0.07, blue: 0.09)
                RadialGradient(colors: [Color.indigo.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 650)
                VStack(spacing: 12) {
                    Text(state.label).font(.system(size: 11, weight: .semibold)).tracking(2.5)
                        .foregroundStyle(Color.white.opacity(0.5)).padding(.top, 32)
                    CommandSpaceView(model: model)
                }
            }
            .frame(width: 960, height: 720)
            .environment(\.colorScheme, .dark)
        }
    }

    private struct LogoFrame: View {
        let mood: SpaceMood
        let prior: SpaceMood
        let time: Double
        let blend: Double
        var body: some View {
            ZStack {
                Color(red: 0.035, green: 0.04, blue: 0.055)
                Ellipse().fill(Color.indigo.opacity(0.12)).frame(width: 600, height: 140).blur(radius: 65).offset(y: 30)
                VStack(spacing: 15) {
                    ZStack {
                        SpaceMark(mood: prior, renderingTime: time).opacity(1 - blend)
                        SpaceMark(mood: mood, renderingTime: time).opacity(blend)
                    }
                    .frame(width: 160, height: 104)
                    Text("Command Space").font(.system(size: 56, weight: .bold)).tracking(-2)
                        .foregroundStyle(.white)
                    Text("Your Mac, one shortcut away.").font(.system(size: 20)).foregroundStyle(Color.white.opacity(0.58))
                }
            }
            .frame(width: 960, height: 380)
        }
    }
}
#endif
