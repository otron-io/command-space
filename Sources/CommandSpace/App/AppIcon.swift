//
//  AppIcon.swift
//  Command Space
//
//  The app icon: Space, the living space bar, on an OLED-black tile, lit from below like a
//  backlit key. `scripts/build-app.sh` renders it
//  with `CommandSpace --render-icon <dir>` and packs it into AppIcon.icns.
//

import AppKit
import SwiftUI

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 228, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.1), .black], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .overlay(RoundedRectangle(cornerRadius: 228, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 4))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
            // Key light: the space bar glows onto the tile beneath it.
            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.45, green: 0.5, blue: 1.0).opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 640, height: 220)
                .offset(y: 170)
                .blur(radius: 30)
            SpaceMark(mood: .idle, animated: false)
                .frame(width: 560)
                .offset(y: -10)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
enum IconRenderer {
    /// Writes icon_16x16.png … icon_512x512@2x.png into `directory` (an .iconset).
    static func render(into directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconView().environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return false }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                guard let scaled = context.makeImage() else { return false }
                let rep = NSBitmapImageRep(cgImage: scaled)
                let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                guard let data = rep.representation(using: .png, properties: [:]),
                      (try? data.write(to: directory.appendingPathComponent(name))) != nil else { return false }
            }
        }
        return true
    }
}

/// `CommandSpace --render-moods <file.png>`: every mood side by side, for checking the mark.
@MainActor
enum MoodSheet {
    static func render(to url: URL) -> Bool {
        let moods: [(String, SpaceMood)] = [("idle", .idle), ("thinking", .thinking), ("working", .working), ("attention", .attention),
                                            ("listening", .listening), ("happy", .happy), ("offline", .offline)]
        let sheet = HStack(spacing: 30) {
            ForEach(moods, id: \.0) { name, mood in
                VStack(spacing: 18) {
                    SpaceMark(mood: mood, animated: false).frame(width: 150)
                    Text(name).font(.system(size: 18, weight: .medium)).foregroundStyle(.gray)
                }
            }
        }
        .padding(50)
        .background(Color.black)
        let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

