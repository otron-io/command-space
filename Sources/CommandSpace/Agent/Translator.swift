//
//  Translator.swift
//  Command Space
//
//  Instant translation with Apple's on-device models (Translation framework). No System Two,
//  no network: a few tens of milliseconds once a language pair is downloaded. Languages that
//  aren't downloaded yet are reported so the UI can offer the download.
//

import AppKit
import Foundation
import SwiftUI
import Translation

struct TranslationResult: Equatable {
    let text: String
    let source: Locale.Language
    let target: Locale.Language

    var directionLabel: String {
        "\(TranslationParsing.displayName(source)) → \(TranslationParsing.displayName(target))"
    }
}

enum TranslationFailure: Error, Equatable {
    /// Supported, but the language isn't downloaded on this Mac.
    case needsDownload(Locale.Language, Locale.Language)
    case unsupported
    case sameLanguage
    case failed
}

@MainActor
final class Translator {
    static let shared = Translator()

    private var sessions: [String: AnyObject] = [:]
    private init() {}

    static var isAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    func translate(_ request: TranslationRequest) async -> Result<TranslationResult, TranslationFailure> {
        guard #available(macOS 26, *) else { return .failure(.unsupported) }
        let text = String(request.text.prefix(5000))
        guard let source = request.source ?? TranslationParsing.detect(text) else { return .failure(.failed) }
        let target = request.target
        if source.languageCode == target.languageCode, source.script == target.script { return .failure(.sameLanguage) }

        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: return .failure(.needsDownload(source, target))
        case .unsupported: return .failure(.unsupported)
        @unknown default: return .failure(.unsupported)
        }
        let key = "\(source.maximalIdentifier)>\(target.maximalIdentifier)"
        let session = (sessions[key] as? TranslationSession) ?? TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        do {
            let response = try await session.translate(text)
            return .success(TranslationResult(text: response.targetText, source: source, target: target))
        } catch {
            sessions[key] = nil
            return .failure(.failed)
        }
    }

    /// System Settings › General › Language & Region, where translation languages are downloaded.
    static func openLanguageDownloads() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Downloading languages

/// A small window that asks macOS to download a language pair (Apple's own download prompt
/// needs a real window; the floating panel can't host it).
@MainActor
final class TranslationDownloader {
    static let shared = TranslationDownloader()
    private var window: NSWindow?

    func download(source: Locale.Language, target: Locale.Language) {
        guard #available(macOS 26, *) else { return Translator.openLanguageDownloads() }
        window?.close()
        let view = TranslationDownloadView(source: source, target: target) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Translation Languages"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

@available(macOS 26, *)
private struct TranslationDownloadView: View {
    let source: Locale.Language
    let target: Locale.Language
    let onDone: () -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var status = "Preparing the download…"
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(TranslationParsing.displayName(source)) ↔ \(TranslationParsing.displayName(target))", systemImage: "translate")
                .font(.headline)
            Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Language & Region…") { Translator.openLanguageDownloads() }
                Spacer()
                Button(finished ? "Done" : "Close") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { configuration = .init(source: source, target: target) }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                status = "Ready. Translations between these languages now run instantly on this Mac."
                finished = true
            } catch {
                status = "The download didn’t finish. You can download languages in Language & Region › Translation Languages."
            }
        }
    }
}
