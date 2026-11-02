import AppKit
import ImageIO
import SwiftUI

/// Only called for an explicit paste. No clipboard monitoring, uploads, or screenshot files.
enum ClipboardImages {
    static let limit = 4
    private static let byteLimit = 32_000_000

    enum PasteError: LocalizedError {
        case unreadable, tooMany
        var errorDescription: String? {
            switch self {
            case .unreadable: "That image couldn’t be read or is too large. Try a smaller PNG or JPEG."
            case .tooMany: "Attach up to four images per message. Remove one before pasting more."
            }
        }
    }

    static func request(_ text: String, images: [ScreenImage]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || images.isEmpty { return text }
        return images.count == 1 ? "Describe this image." : "Describe these images."
    }

    /// Downsample and re-encode: bounded dimensions, no source EXIF metadata, preserved alpha.
    static func prepare(_ data: Data) throws -> ScreenImage {
        guard data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= 4_000_000 else { throw PasteError.unreadable }
        return ScreenImage(data: png, mimeType: "image/png")
    }

    @MainActor static func read(from pasteboard: NSPasteboard) throws -> [ScreenImage] {
        var images: [ScreenImage] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("org.webmproject.webp")]
            if let type = types.first(where: { item.types.contains($0) }) {
                guard let data = item.data(forType: type) else { throw PasteError.unreadable }
                images.append(try prepare(data))
            } else if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL,
                      ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? byteLimit + 1
                guard size <= byteLimit else { throw PasteError.unreadable }
                images.append(try prepare(Data(contentsOf: url, options: .mappedIfSafe)))
            }
            if images.count > limit { throw PasteError.tooMany }
        }
        return images
    }

    /// The field editor retains macOS's normal insertion, selection, and undo behavior.
    @MainActor static func pasteText(from pasteboard: NSPasteboard, into editor: NSTextView) -> Bool {
        guard editor.isEditable else { return false }
        if pasteboard === NSPasteboard.general {
            editor.paste(nil)
            return true
        }
        // Named pasteboards let UI tests exercise native insertion without changing the user's clipboard.
        return editor.readSelection(from: pasteboard)
    }
}

struct ImageAttachmentStrip: View {
    @Binding var images: [ScreenImage]
    var error: String?
    var width: CGFloat? = Space.barWidth

    var body: some View {
        if !images.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            if let preview = NSImage(data: image.data) {
                                HStack(spacing: 6) {
                                    Image(nsImage: preview).resizable().scaledToFit()
                                        .frame(width: 54, height: 42)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Button { images.remove(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove image \(index + 1)")
                                    .accessibilityLabel("Remove image \(index + 1)")
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(images.count) image\(images.count == 1 ? "" : "s") · System Two")
                                .foregroundStyle(.cyan)
                            Text("Add a question, then press ⏎").foregroundStyle(.gray)
                        }
                        .font(.system(size: 10.5))
                    }
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            }
            .padding(12)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Space.hairline, lineWidth: 0.75))
        }
    }
}
