import SwiftUI
import CopyCore
import ImageIO
import UniformTypeIdentifiers

struct PreviewPane: View {
    let item: ClipItem
    let store: ItemStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imagePixelSize: CGSize?

    private var previewSize: CGSize {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        if item.kind == .image || imagePixelSize != nil {
            return PreviewLayout.imageSize(pixels: imagePixelSize ?? CGSize(width: 1200, height: 900),
                                           screen: available, scale: screen?.backingScaleFactor ?? 2)
        }
        if [.text, .richText, .link].contains(item.kind) {
            return PreviewLayout.textSize(text: String((item.plainText ?? "").prefix(200_000)), screen: available)
        }
        return CGSize(width: 420, height: 320)
    }

    private var quickLookURLs: [URL] {
        QuickLookController.fileURLs(for: item, store: store)
    }

    /// How much of the preview's text ever gets tokenized for syntax color. The pane
    /// shows a bounded window, so 10k characters is
    /// comfortably more than anything on screen for realistic pastes; a 500KB code
    /// paste stays instant because tokenization work is bounded by this cap, not by
    /// the paste's actual size. Anything beyond the cap still renders (up to the
    /// existing 200k display cap below), just without color.
    private let highlightCap = 10_000

    /// Builds the default-branch preview text: the same 200k-character display cap as
    /// before, with syntax colors applied to only the first `highlightCap` characters
    /// of that (detection + tokenization are cached per item by `CodeHighlightCache`).
    /// Any remainder past the highlighted portion still renders, just as plain mono
    /// text, exactly as the whole thing did before this feature existed.
    private func codeAwarePreviewText(_ text: String) -> Text {
        let displayText = String(text.prefix(200_000))
        let cap = min(displayText.count, highlightCap)
        let highlightPortion = String(displayText.prefix(cap))
        let highlight = CodeHighlightCache.shared.result(for: text, uuid: item.uuid, cap: cap)
        guard highlight.language != nil else { return Text(displayText) }

        guard displayText.count > highlightPortion.count else {
            return highlightedText(highlightPortion, tokens: highlight.tokens)
        }
        let remainder = String(displayText.dropFirst(highlightPortion.count))
        return highlightedText(highlightPortion, tokens: highlight.tokens) + Text(remainder)
    }

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                StoredImagePreview(item: item, store: store) { imagePixelSize = $0 }
                    .padding(12)
            case .color:
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Tokens.color(fromHex: item.plainText ?? ""))
                    Text(item.plainText ?? "")
                        .font(.system(size: 15, design: .monospaced))
                }
                .padding(16)
            case .file:
                FileCardPreview(item: item, urls: quickLookURLs) { imagePixelSize = $0 }
            default:
                ScrollView {
                    codeAwarePreviewText(item.plainText ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: previewSize)
        // M7: the popover's own chrome is otherwise unstyled (SwiftUI/AppKit gives it
        // a plain system background), so this is a clean single-surface adoption —
        // glass on 26 with Reduce Transparency off, the app's existing `.hudWindow`
        // material otherwise. `clipShape` mirrors `PasteStackView`'s treatment so the
        // `ScrollView` text case (the `default` branch above) doesn't bleed square
        // corners past the rounded backing on either code path.
        .glassSurface(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Decodes a clipboard-backed image at preview resolution rather than scaling the
/// shelf's 400-pixel thumbnail into a large popover. Metadata is read before decoding
/// so the parent can size the popover from the original, orientation-corrected pixels.
private struct StoredImagePreview: View {
    let item: ClipItem
    let store: ItemStore
    let onPixelSize: (CGSize) -> Void
    @State private var image: NSImage?
    @State private var didFail = false
    @State private var didStart = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didFail {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        guard !didStart, let id = item.id else {
            if item.id == nil { didFail = true }
            return
        }
        didStart = true
        DispatchQueue.global(qos: .userInitiated).async {
            let reps = (try? store.representations(forItemID: id)) ?? []
            let data = reps.first(where: { $0.uti == "public.png" })?.data
                ?? reps.first(where: { $0.uti == "public.tiff" })?.data
            let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            let pixelSize = source.flatMap(PreviewImageDecoder.orientedPixelSize)
            let cgImage = source.flatMap(PreviewImageDecoder.previewImage)
            let decoded = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            DispatchQueue.main.async {
                if let pixelSize { onPixelSize(pixelSize) }
                image = decoded
                didFail = decoded == nil
            }
        }
    }
}

/// Decodes an image-file card from its original URL for the larger Space preview.
/// This deliberately does not use the 400-point Quick Look thumbnail used by shelf
/// cards: ImageIO downsamples the source itself at a size suitable for a Retina pane.
private struct FileImagePreview: View {
    let url: URL
    let onPixelSize: (CGSize) -> Void
    @State private var image: NSImage?
    @State private var didFail = false
    @State private var didStart = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didFail {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        guard !didStart else { return }
        didStart = true
        let requestedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGImageSourceCreateWithURL(requestedURL as CFURL, nil)
            let pixelSize = source.flatMap(PreviewImageDecoder.orientedPixelSize)
            let cgImage = source.flatMap(PreviewImageDecoder.previewImage)
            let decoded = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            DispatchQueue.main.async {
                if let pixelSize { onPixelSize(pixelSize) }
                image = decoded
                didFail = decoded == nil
            }
        }
    }
}

private enum PreviewImageDecoder {
    static func orientedPixelSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height.doubleValue, height: width.doubleValue)
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func previewImage(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}

/// The Space preview for a file card. Deciding whether the card points at an image means
/// asking the file system for each URL's content type, and that call blocks for as long
/// as the volume takes to answer — unbounded on a network share or a sleeping disk. The
/// probe therefore runs off the main thread, and the pane shows the same spinner
/// `FileImagePreview` uses while it decodes, so the generic icon never flashes first.
private struct FileCardPreview: View {
    let item: ClipItem
    let urls: [URL]
    let onPixelSize: (CGSize?) -> Void
    @State private var imageURL: URL?
    @State private var didProbe = false

    var body: some View {
        Group {
            if let imageURL {
                FileImagePreview(url: imageURL) { onPixelSize($0) }
                    .id(imageURL)
                    .padding(12)
            } else if didProbe {
                genericFile
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.uuid) {
            imageURL = nil
            onPixelSize(nil)
            didProbe = false
            let candidates = urls
            let found = await Task.detached(priority: .userInitiated) {
                candidates.first { url in
                    guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
                          let contentType = values.contentType else { return false }
                    return contentType.conforms(to: .image)
                }
            }.value
            guard !Task.isCancelled else { return }
            imageURL = found
            didProbe = true
        }
    }

    private var genericFile: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: Tokens.fileType(for: item)))
                .resizable()
                .frame(width: 64, height: 64)
            Text(item.plainText ?? "File")
                .font(.system(size: 13, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(4)
            if !urls.isEmpty {
                Button("Quick Look") {
                    QuickLookController.shared.preview(urls)
                }
            }
        }
        .padding(16)
    }
}
