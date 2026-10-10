import AppKit
import CopyCore

/// Populates a store with curated mock clipboard data for screenshots and demo videos.
/// Only invoked in demo mode (`AppCoordinator` with `--demo`), against the isolated,
/// reset-every-launch `DemoData` database — never the real one. Timestamps are relative to
/// launch, so cards read "2m / 1h / yesterday / last week" and every Time facet has hits.
enum DemoData {
    typealias App = (bundleID: String, name: String)
    private static let safari: App = ("com.apple.Safari", "Safari")
    private static let slack: App = ("com.tinyspeck.slackmacgap", "Slack")
    private static let notes: App = ("com.apple.Notes", "Notes")
    private static let figma: App = ("com.figma.Desktop", "Figma")
    private static let xcode: App = ("com.apple.dt.Xcode", "Xcode")
    private static let terminal: App = ("com.apple.Terminal", "Terminal")
    private static let vscode: App = ("com.microsoft.VSCode", "Visual Studio Code")
    private static let whatsapp: App = ("net.whatsapp.WhatsApp", "WhatsApp")
    private static let finder: App = ("com.apple.finder", "Finder")
    private static let mail: App = ("com.apple.mail", "Mail")

    @MainActor
    static func seed(store: ItemStore, pinboards: PinboardStore, pasteStack: PasteStackModel) {
        do {
            try seedThrowing(store: store, pinboards: pinboards, pasteStack: pasteStack)
        } catch {
            NSLog("Copy: demo seed failed: \(error)")
        }
    }

    @MainActor
    private static func seedThrowing(store: ItemStore, pinboards: PinboardStore, pasteStack: PasteStackModel) throws {
        let now = Date()
        let minute = 60.0, hour = 3600.0, day = 86400.0
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

        // MARK: builders

        @discardableResult
        func text(_ content: String, from app: App, at: Date, kind: ItemKind = .text) throws -> Int64 {
            let item = try store.save(CapturedItem(
                kind: kind, plainText: content, hashData: Data(content.utf8),
                representations: [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(content.utf8))],
                sourceBundleID: app.bundleID, sourceAppName: app.name), now: at)
            return item.id ?? 0
        }

        @discardableResult
        func link(_ url: String, title: String, from app: App, at: Date, favicon: NSColor) throws -> Int64 {
            let id = try text(url, from: app, at: at, kind: .link)
            try store.setLinkTitle(itemID: id, title)
            try store.setFavicon(itemID: id, pngData: solidPNG(favicon, size: 32))
            return id
        }

        @discardableResult
        func image(from app: App, at: Date, top: NSColor, bottom: NSColor, label: String? = nil, ocr: String? = nil) throws -> Int64 {
            let png = gradientPNG(top: top, bottom: bottom, text: label)
            let item = try store.save(CapturedItem(
                kind: .image, plainText: "Image", hashData: png,
                representations: [CapturedRepresentation(uti: "public.png", data: png)],
                sourceBundleID: app.bundleID, sourceAppName: app.name), now: at)
            let id = item.id ?? 0
            if let ocr { try store.setRecognizedText(itemID: id, ocr) }
            return id
        }

        @discardableResult
        func color(_ hex: String, from app: App, at: Date) throws -> Int64 {
            let item = try store.save(CapturedItem(
                kind: .color, plainText: hex, hashData: Data(("color" + hex).utf8),
                representations: [CapturedRepresentation(uti: CopyPasteboard.colorType, data: Data(hex.utf8))],
                sourceBundleID: app.bundleID, sourceAppName: app.name), now: at)
            return item.id ?? 0
        }

        @discardableResult
        func file(_ path: String, from app: App, at: Date) throws -> Int64 {
            let url = URL(fileURLWithPath: path)
            let item = try store.save(CapturedItem(
                kind: .file, plainText: url.lastPathComponent, hashData: Data(path.utf8),
                representations: [CapturedRepresentation(uti: "public.file-url", data: url.dataRepresentation)],
                sourceBundleID: app.bundleID, sourceAppName: app.name), now: at)
            return item.id ?? 0
        }

        // MARK: items (most recent first for a natural shelf order)

        let swiftCode = """
        func paste(_ item: ClipItem) {
            guard let next = queue.advance() else { return }
            pasteboard.write(next.representations)
            HUD.show("Pasted \\(next.displayTitle)")
        }
        """
        let codeID = try text(swiftCode, from: xcode, at: ago(2 * minute))

        let invoiceID = try image(from: safari, at: ago(6 * minute),
                                  top: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
                                  bottom: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                                  label: "INVOICE #A-2214",
                                  ocr: "INVOICE #A-2214  total due $4,820.00  net 30")

        let githubID = try link("https://github.com/tarikbc/Copy",
                                title: "tarikbc/Copy: a visual clipboard for macOS",
                                from: safari, at: ago(9 * minute), favicon: NSColor(calibratedWhite: 0.13, alpha: 1))

        let sketchID = try file("/Users/tarik/Design/Copy-hero.sketch", from: finder, at: ago(12 * minute))

        let brandColorID = try color("#4C9DFF", from: figma, at: ago(16 * minute))
        try color("4c9dff", from: figma, at: ago(18 * minute))  // no '#' — still a swatch

        let tsCode = """
        export function useClipboard() {
          const [items, setItems] = useState<Item[]>([])
          useEffect(() => subscribe(setItems), [])
          return items
        }
        """
        let tsID = try text(tsCode, from: vscode, at: ago(22 * minute))

        let checklistID = try text(
            "Launch checklist:\n1. Notarize + staple\n2. Update the appcast\n3. Bump the Homebrew cask\n4. Post the demo video",
            from: notes, at: ago(28 * minute))
        try store.setTitle(itemID: checklistID, "Launch checklist")

        // Fake secrets to show Hide Secrets, assembled from pieces so secret scanners ignore them.
        let fakeOpenAIKey = "sk" + "-proj-" + "FAKEfakeFAKEfake1234567890abcd"
        let fakeStripeKey = "sk" + "_test_" + "FAKE0000FAKE0000FAKE0000"
        let fakeGitHubToken = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let envID = try text(
            "APP_ENV=staging\nOPENAI_API_KEY=\(fakeOpenAIKey)\nSTRIPE_SECRET_KEY=\(fakeStripeKey)\nDB_PASSWORD=Tr0ub4dor-and-3-more\nLOG_LEVEL=debug",
            from: vscode, at: ago(24 * minute))
        try store.setTitle(itemID: envID, ".env (staging)")
        try text(fakeGitHubToken, from: terminal, at: ago(25 * minute))
        try text("Card on file: 4242 4242 4242 4242, exp 04/29. Use it for the domain renewal.",
                 from: mail, at: ago(26 * minute))
        try link("https://api.example.com/v1/export?format=csv&access_token=a1b2c3d4e5f6g7h8i9j0",
                 title: "Export — Example API",
                 from: safari, at: ago(27 * minute), favicon: .systemTeal)

        let figmaLinkID = try link("https://figma.com/file/9aB2/Copy-Marketing",
                                   title: "Copy — Marketing site (Figma)",
                                   from: figma, at: ago(34 * minute), favicon: .systemPurple)

        try text("Standup at 10:30 — demo the smart search and paste stack. Can someone record the video? 🎥",
                 from: slack, at: ago(45 * minute))

        let jsonCode = """
        {
          "app": "Copy",
          "version": "0.1.3",
          "kinds": ["text", "link", "image", "color", "file"]
        }
        """
        let jsonID = try text(jsonCode, from: vscode, at: ago(1 * hour))
        try store.setTitle(itemID: jsonID, "release manifest")

        let mockupID = try image(from: figma, at: ago(1 * hour + 20 * minute),
                                 top: NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.0, alpha: 1),
                                 bottom: NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.95, alpha: 1),
                                 label: "Shelf mock")

        try text("Chris: sounds great, I'll put the playlist on today 🎧", from: whatsapp, at: ago(2 * hour))

        let shellID = try text("brew install --cask tarikbc/tap/copy && open -a Copy",
                               from: terminal, at: ago(3 * hour))

        try image(from: finder, at: ago(4 * hour),
                  top: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.30, alpha: 1),
                  bottom: NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.35, alpha: 1))

        try text("Ship to: 742 Evergreen Terrace, Springfield, OR 97477", from: mail, at: ago(5 * hour))

        // Older, for the Time facets:
        try link("https://pasteapp.io", title: "Paste — the clipboard for your Mac",
                 from: safari, at: ago(1 * day + 2 * hour), favicon: .systemBlue)
        try text("Q3 roadmap: sync, snippets, and a menu-bar mini shelf.", from: notes, at: ago(1 * day + 4 * hour))
        try text("Reminder: renew the Developer ID cert before it expires.", from: slack, at: ago(5 * day))
        try link("https://developer.apple.com/notarization",
                 title: "Notarizing macOS software before distribution",
                 from: safari, at: ago(6 * day), favicon: .systemGray)
        try color("#34C759", from: figma, at: ago(20 * day))                              // ~last month
        try image(from: figma, at: ago(35 * day),                                          // ~last 3 months
                  top: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.55, alpha: 1),
                  bottom: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.45, alpha: 1),
                  label: "Old concept")

        // MARK: favorites (float above the divider)

        for id in [codeID, githubID, invoiceID, brandColorID] {
            try store.setFavorite(itemID: id, true)
        }

        // MARK: pinboards

        let work = try pinboards.create(name: "Work", symbol: "briefcase", tint: "007AFF")
        let design = try pinboards.create(name: "Design", symbol: "paintpalette", emoji: "🎨", tint: "FF375F")
        let snippets = try pinboards.create(name: "Snippets", symbol: "chevron.left.forwardslash.chevron.right", tint: "34C759")

        for id in [githubID, checklistID, figmaLinkID] where work.id != nil {
            try pinboards.add(itemID: id, to: work.id!)
        }
        for id in [invoiceID, mockupID, brandColorID, sketchID] where design.id != nil {
            try pinboards.add(itemID: id, to: design.id!)
        }
        for id in [codeID, tsID, jsonID, shellID] where snippets.id != nil {
            try pinboards.add(itemID: id, to: snippets.id!)
        }

        // MARK: paste stack (pre-filled; the palette isn't auto-shown)

        let saved = try store.recentItems(limit: 200)
        func uuid(of id: Int64) -> String? { saved.first { $0.id == id }?.uuid }
        for uuid in [shellID, githubID, brandColorID].compactMap(uuid(of:)) {
            pasteStack.queue.enqueue(uuid)
        }
    }

    // MARK: image generation (no bundled assets)

    private static func gradientPNG(top: NSColor, bottom: NSColor, text: String?, width: Int = 520, height: Int = 340) -> Data {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        if let text {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let textHeight = attributed.size().height
            attributed.draw(in: NSRect(x: 0, y: (size.height - textHeight) / 2, width: size.width, height: textHeight))
        }
        image.unlockFocus()
        return png(from: image)
    }

    private static func solidPNG(_ color: NSColor, size dimension: Int) -> Data {
        let size = NSSize(width: dimension, height: dimension)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return png(from: image)
    }

    private static func png(from image: NSImage) -> Data {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return Data() }
        return data
    }
}
