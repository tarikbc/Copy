import SwiftUI
import CopyCore

struct ItemCardView: View {
    let item: ClipItem
    let isSelected: Bool
    /// Whether this card's title is currently the inline click-to-edit field rather
    /// than static `Text` — mirrors `ShelfViewModel.inlineRenamingItemID == item.id`,
    /// computed by the caller since this view has no view-model access of its own.
    let isInlineRenaming: Bool
    let store: ItemStore
    let pinboards: [Pinboard]
    let currentPinboardID: Int64?
    /// Compact shelf mode (`SettingsStore.compactShelf`, threaded from `ShelfRootView`):
    /// smaller card frame + tighter line limits so more cards fit on screen at once.
    var compact: Bool = false
    /// The active search text, used to show and highlight the matched OCR snippet under
    /// an image result. Empty when not searching.
    var searchQuery: String = ""
    /// Briefly true after a "Show in History" jump lands on this card — draws an accent ring.
    var isFlashing: Bool = false
    /// The card's ⌥-digit paste number (1-9), shown as a badge while ⌥ is held; `nil` hides it.
    var pasteNumber: Int? = nil
    /// Whether the "Show in History" context item applies (a search/filter is active, or the
    /// card is on a pinboard tab) — hidden in the plain History browse where it's a no-op.
    var canShowInHistory: Bool = false
    /// A card click always fires immediately here (select), and pasting-on-click is
    /// decided in `ShelfViewModel.handleCardClick` from the selection state — see
    /// `CardClickGesture` for why there is no separate double-click gesture.
    let onClick: (NSEvent.ModifierFlags) -> Void
    /// Reports pointer enter/leave so the shelf can track which card is hovered (used by
    /// force-click-to-preview).
    let onHoverChanged: (Bool) -> Void
    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onEdit: () -> Void
    let onAdjustColor: () -> Void
    /// Enters inline title-editing (see `isInlineRenaming`) — wired from both the
    /// title text's tap gesture and the context menu's "Rename…" item.
    let onBeginInlineRename: () -> Void
    let onCommitInlineRename: (String) -> Void
    let onCancelInlineRename: () -> Void
    let onToggleFavorite: () -> Void
    let onAddToPinboard: (Int64) -> Void
    let onRemoveFromPinboard: () -> Void
    let onAddToPasteStack: () -> Void
    let onCopyText: () -> Void
    let onQuickLook: () -> Void
    let onOpen: () -> Void
    let onShowInHistory: () -> Void
    let onRotate: (Bool) -> Void
    let onDelete: () -> Void
    let dragProvider: () -> NSItemProvider
    /// How many cards this drag carries. >1 when the card is part of a multi-selection,
    /// so the compact drag preview can show a "+N" badge. Defaults to a single card.
    var dragBadgeCount: Int = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isEditable: Bool {
        switch item.kind {
        case .text, .richText, .link: return true
        case .image, .file, .color: return false
        }
    }

    /// File URL(s) still on disk for this item, used to gate the "Quick Look" menu
    /// item — see `QuickLookController.fileURLs(for:store:)`.
    private var quickLookURLs: [URL] {
        QuickLookController.fileURLs(for: item, store: store)
    }

    /// The user-assigned title, if any. When set it takes the header's primary-label
    /// slot in place of the app name (see `header`).
    private var customTitle: String? {
        guard let title = item.title, !title.isEmpty else { return nil }
        return title
    }

    /// The header's primary label: the custom title if the user set one; otherwise "Image"
    /// for image cards (their source app is rarely meaningful), or the source app's name.
    /// Clicking it renames the card either way.
    private var headerLabel: String {
        if let customTitle { return customTitle }
        if item.kind == .image { return "Image" }
        return item.appName ?? "Unknown"
    }

    /// A kind's body line limit for the current layout mode. The title now lives in the
    /// header rather than a separate row above the body, so the body always gets its full
    /// height regardless of whether a title is set.
    private func bodyLineLimit(standard: Int, compact compactValue: Int) -> Int {
        compact ? compactValue : standard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            header
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 1)
            body(for: item.kind)
            Spacer(minLength: 0)
            footer
        }
        .padding(compact ? 8 : 10)
        .frame(width: Tokens.cardWidth(compact: compact), height: Tokens.cardHeight(compact: compact), alignment: .topLeading)
        // M7: deliberately NOT routed through `glassSurface` even on macOS 26. Cards
        // are dense, content-bearing surfaces (up to 11 lines of mono-spaced clipboard
        // text) shown many-at-a-time in a scrolling row — exactly the case Apple's
        // Liquid Glass guidance calls out as the wrong fit ("glass is for the controls
        // and navigation that float above content, not for the content itself"). The
        // shelf panel behind the row is already glass on 26 (`ShelfRootView`); stacking
        // another translucent layer under small text-heavy cards would fight the mono
        // body text's legibility and read as busy rather than intentional. Cards keep
        // `controlBackgroundColor` on every macOS version.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if isSelected {
                    RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom)
                        )
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 2 : 1)
        )
        // "Show in History" flash: an accent ring that fades in then out as `isFlashing`
        // toggles (set on jump, cleared ~1s later by the view model).
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 3)
                .opacity(isFlashing ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isFlashing)
        )
        // ⌥-digit paste hint: a numbered badge shown while ⌥ is held, so users discover that
        // ⌥1-9 pastes the Nth card.
        .overlay(alignment: .topLeading) {
            if let pasteNumber {
                Text("\(pasteNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            // On hover, surface the two most-buried card actions (favorite, delete) as a
            // floating pill so they're discoverable without opening the context menu.
            // Otherwise, just the quiet favorite indicator when the card is favorited.
            if isHovering && !isInlineRenaming {
                CardHoverActions(isFavorite: item.isFavorite,
                                 onToggleFavorite: onToggleFavorite,
                                 // Only offer unpin while viewing a pinboard, where the card
                                 // actually belongs to one it can be removed from.
                                 onUnpin: currentPinboardID != nil ? onRemoveFromPinboard : nil,
                                 onDelete: onDelete)
                    .padding(5)
                    .transition(.opacity)
            } else if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .accessibilityLabel("Favorite")
            }
        }
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            onHoverChanged(hovering)
        }
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        // A soft accent glow lifts the selected card off the row in dark mode, matching
        // the shelf's Liquid Glass depth. In light mode a colored halo reads heavy, so
        // the selection there relies on the accent border + gradient fill alone.
        .shadow(color: (isSelected && colorScheme == .dark) ? Color.accentColor.opacity(0.32) : .clear,
                radius: (isSelected && colorScheme == .dark) ? 8 : 0, y: 1)
        // A gentle spring on the selection border/fill/glow so moving between cards reads
        // as one cohesive motion rather than an instant snap. Scoped to `isSelected` so it
        // never animates content changes; skipped under Reduce Motion.
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72), value: isSelected)
        .contextMenu {
            if canShowInHistory {
                Button("Show in History", action: onShowInHistory)
                    .keyboardShortcut("g", modifiers: .command)
                Divider()
            }
            Button("Paste", action: onPaste)
            Button("Paste as Plain Text", action: onPastePlain)
            if item.kind == .link || item.kind == .file {
                Button("Open", action: onOpen)
                    .keyboardShortcut("o", modifiers: .command)
            }
            if item.recognizedText?.isEmpty == false {
                Button("Copy Text", action: onCopyText)
            }
            if item.kind == .file, !quickLookURLs.isEmpty {
                Button("Quick Look", action: onQuickLook)
            }
            if item.kind == .image {
                Button("Rotate Left") { onRotate(false) }
                Button("Rotate Right") { onRotate(true) }
            }
            Divider()
            if isEditable {
                Button("Edit…", action: onEdit)
                    .keyboardShortcut("e", modifiers: .command)
            } else if item.kind == .color {
                Button("Adjust Color…", action: onAdjustColor)
            }
            Button("Rename…", action: onBeginInlineRename)
            Button(item.isFavorite ? "Unfavorite" : "Favorite", action: onToggleFavorite)
            Menu("Add to Pinboard") {
                if pinboards.isEmpty {
                    Text("No Pinboards")
                } else {
                    ForEach(pinboards, id: \.id) { pinboard in
                        Button {
                            if let id = pinboard.id { onAddToPinboard(id) }
                        } label: {
                            Label(pinboard.name, systemImage: pinboard.symbol)
                        }
                    }
                }
            }
            Button("Add to Paste Stack", action: onAddToPasteStack)
            if currentPinboardID != nil {
                Button("Remove from Pinboard", action: onRemoveFromPinboard)
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onDrag(dragProvider) { dragPreview }
        .modifier(CardClickGesture(onClick: onClick))
    }

    /// A small chip shown under the cursor while dragging, instead of SwiftUI's default
    /// full-size snapshot of the card. The full card covered the little pinboard tabs,
    /// making it impossible to tell which one you were about to drop onto; this keeps the
    /// tabs (and their drop highlight) visible.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            dragPreviewGlyph
            Text(item.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if dragBadgeCount > 1 {
                Text("+\(dragBadgeCount - 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 240)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder private var dragPreviewGlyph: some View {
        Group {
            if item.kind == .image {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else if item.kind == .color {
                Circle().fill(Tokens.color(fromHex: item.plainText ?? ""))
            } else if let icon = AppIconCache.icon(forBundleID: item.appBundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
    }

    private var header: some View {
        HStack(spacing: 5) {
            // The icon steps aside while renaming so the inline field gets the full width.
            // Image cards show a photo glyph (their source app is rarely meaningful);
            // everything else shows the source app's icon.
            if !isInlineRenaming {
                if item.kind == .image {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                } else if let icon = AppIconCache.icon(forBundleID: item.appBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            if isInlineRenaming {
                InlineTitleField(
                    initialText: item.title ?? "",
                    onCommit: onCommitInlineRename,
                    onCancel: onCancelInlineRename
                )
            } else {
                // The card's name: the custom title if set, otherwise the source app.
                // Clicking it begins an inline rename; scoped to this text so it wins over
                // `CardClickGesture` (SwiftUI routes a tap to the deepest view with a
                // gesture), and the click never also selects/pastes the card.
                Text(headerLabel)
                    .font(customTitle != nil ? Tokens.cardSubtitle : Tokens.cardTitle)
                    .foregroundStyle(customTitle != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .onTapGesture { onBeginInlineRename() }
                Spacer(minLength: 4)
                Text(Tokens.relativeFormatter.localizedString(for: item.lastUsedAt, relativeTo: Date()))
                    .font(Tokens.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Renders `text` (capped to `cap` characters, same as the plain-text path always
    /// did) with syntax colors when `CodeDetector` recognizes it as code, otherwise as
    /// plain `Text` exactly as before this feature existed. Detection + tokenization
    /// are cached per item (`CodeHighlightCache`) so scrolling the shelf doesn't
    /// re-run them every frame; "Copy"/paste are untouched — this only changes what's
    /// drawn on screen.
    @ViewBuilder
    private func codeAwareBody(text: String, cap: Int) -> some View {
        let capped = String(text.prefix(cap))
        let highlight = CodeHighlightCache.shared.result(for: text, uuid: item.uuid, cap: cap)
        let display = Self.preservingIndentation(capped)
        if highlight.language != nil {
            highlightedText(display, tokens: highlight.tokens)
        } else {
            Text(display)
        }
    }

    /// Replaces each line's leading whitespace with non-breaking spaces so SwiftUI keeps
    /// the code's indentation (`Text` otherwise collapses leading whitespace when a line
    /// wraps). One-for-one (space/tab → one NBSP) so it never shifts the highlight token
    /// ranges, which are computed against the original text.
    private static func preservingIndentation(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            guard indent > 0 else { return String(line) }
            return String(repeating: "\u{00A0}", count: indent) + line.dropFirst(indent)
        }.joined(separator: "\n")
    }

    /// Text/rich-text card body. When the whole item is a hex color (e.g. someone
    /// copied "#4C9DFF"), show the actual color as a swatch instead of the raw string;
    /// otherwise render the (optionally code-highlighted) text. Extracted from
    /// `body(for:)` to keep that switch simple enough for the Swift type checker.
    @ViewBuilder
    private var textBody: some View {
        if let hex = HexColor.normalized(item.plainText ?? "") {
            colorSwatchBody(hex)
        } else {
            codeAwareBody(text: item.plainText ?? "", cap: 1_500)
                .font(Tokens.bodyMono)
                .lineLimit(bodyLineLimit(standard: 11, compact: 6))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// A color swatch plus its hex, matching the `.color` card, used for both real
    /// color items and text items that are themselves a hex color.
    private func colorSwatchBody(_ hex: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.color(fromHex: hex))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(hex).font(Tokens.bodyMono)
        }
    }

    /// File card body: a Finder-style Quick Look preview of the file, with its name
    /// below. Extracted from `body(for:)` for the Swift type checker.
    @ViewBuilder
    private var fileBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            FileThumbnail(item: item, store: store, compact: compact)
            Text(item.plainText ?? "File")
                .font(Tokens.bodyMono)
                .lineLimit(bodyLineLimit(standard: 2, compact: 1))
        }
    }

    /// Image card body: the thumbnail, plus a highlighted OCR snippet when a search
    /// matched the image's recognized text. Extracted from `body(for:)` so the switch
    /// there stays simple enough for the Swift type checker.
    @ViewBuilder
    private var imageBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardThumbnail(item: item, store: store)
            if !searchQuery.isEmpty, let ocr = item.recognizedText,
               let snippet = OCRSnippet.make(recognizedText: ocr, query: searchQuery) {
                highlightedSnippet(snippet, query: searchQuery)
                    .font(Tokens.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Renders an OCR snippet with the matched query span tinted, so an image search
    /// result shows why it matched. Content coloring only (no card stripe).
    private func highlightedSnippet(_ snippet: String, query: String) -> Text {
        guard let range = snippet.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(snippet)
        }
        let before = String(snippet[snippet.startIndex..<range.lowerBound])
        let match = String(snippet[range])
        let after = String(snippet[range.upperBound..<snippet.endIndex])
        return Text(before) + Text(match).foregroundColor(.accentColor).fontWeight(.semibold) + Text(after)
    }

    @ViewBuilder
    private func body(for kind: ItemKind) -> some View {
        switch kind {
        case .text, .richText:
            textBody
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    LinkFaviconView(item: item, store: store)
                    Text(item.linkTitle ?? URL(string: item.plainText ?? "")?.host ?? "Link")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(bodyLineLimit(standard: 2, compact: 1))
                        .multilineTextAlignment(.leading)
                }
                // Give the URL the remaining body lines while keeping the footer visible.
                Text(String((item.plainText ?? "").prefix(1_500)))
                    .font(Tokens.bodyMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(bodyLineLimit(standard: 8, compact: 3))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        case .image:
            imageBody
        case .file:
            fileBody
        case .color:
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tokens.color(fromHex: item.plainText ?? ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.plainText ?? "")
                    .font(Tokens.bodyMono)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: footerGlyph)
                .font(.system(size: 9))
            Text(footerText)
                .font(Tokens.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.tertiary)
    }

    private var footerGlyph: String {
        switch item.kind {
        case .text, .richText: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    private var footerText: String {
        switch item.kind {
        case .text, .richText:
            if item.sizeBytes > 100_000 {
                return ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file)
            }
            return "\(item.plainText?.count ?? 0) characters"
        case .link:
            return URL(string: item.plainText ?? "")?.host ?? "Link"
        case .image:
            return "Image"
        case .file:
            let count = item.plainText?.components(separatedBy: "\n").count ?? 1
            return count == 1 ? "1 file" : "\(count) files"
        case .color:
            return "Color"
        }
    }
}

struct LinkFaviconView: View {
    let item: ClipItem
    let store: ItemStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "link")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .onAppear(perform: loadImage)
        // Metadata persistence updates the item title after writing its favicon. The
        // view may already be mounted by then, so `onAppear` alone would leave its
        // earlier nil lookup stuck until the app relaunched.
        .onChange(of: item.linkTitle) { _, _ in loadImage() }
    }

    private func loadImage() {
        guard image == nil else { return }
        image = FaviconCache.shared.cached(for: item)
        if image == nil {
            FaviconCache.shared.favicon(for: item, store: store) { loaded in
                // An older miss must not overwrite a newer successful lookup.
                if let loaded { image = loaded }
            }
        }
    }
}

/// Inline, click-to-edit title field shown in place of the title `Text` while a
/// card is being renamed (`ItemCardView.isInlineRenaming`). Enter commits, Escape
/// reverts without saving, and losing focus (clicking away) commits — the field
/// is auto-focused on appear so typing can start immediately.
private struct InlineTitleField: View {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool
    /// Guards `commit()`/`cancel()` against running twice for the same edit: Return
    /// fires `.onSubmit` (commit), Escape fires `.onExitCommand` (cancel), and
    /// `.onDisappear` (below) commits as a catch-all when the field leaves the tree
    /// for any other reason — each of those also drops focus as a side effect, which
    /// would otherwise re-trigger the `onChange(of: isFocused)` focus-loss commit on
    /// the same resolution.
    @State private var isResolved = false

    init(initialText: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        TextField("Title", text: $text)
            .textFieldStyle(.plain)
            .font(Tokens.cardSubtitle)
            .lineLimit(1)
            .focused($isFocused)
            .onAppear {
                // Dispatched async: this field lives inside a LazyHStack card row, and
                // focusing synchronously on `.onAppear` can lose the race with SwiftUI
                // still installing the view in the window's responder chain.
                DispatchQueue.main.async { isFocused = true }
            }
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            // Catch-all for teardown paths `onChange(of: isFocused)` doesn't reliably
            // cover — e.g. this card's `isInlineRenaming` flips to false because a
            // DIFFERENT card started renaming (branch-swap back to the title `Text`,
            // not a focus change on this view), or the row disappears from the shelf
            // entirely mid-edit. `.onDisappear` always fires when a view leaves the
            // render tree, so an in-progress edit is saved rather than silently
            // dropped. `isResolved` keeps this a no-op after Enter/Esc already
            // resolved the edit.
            .onDisappear { commit() }
    }

    private func commit() {
        guard !isResolved else { return }
        isResolved = true
        onCommit(text)
    }

    private func cancel() {
        guard !isResolved else { return }
        isResolved = true
        onCancel()
    }
}

/// Card click handling. The double-tap recognizer must be registered before the
/// single-tap one, or SwiftUI never resolves the double-click. We attach it ONLY in
/// double-click-to-paste mode: in single-click-paste mode a lone single-tap recognizer
/// pastes immediately, with none of the double-click-interval latency an always-present
/// count:2 recognizer would impose on every click. The count:2 gesture carries no
/// modifier flags, which is fine: pasting on double-click is a no-modifier gesture, and
/// modifier multi-select stays a single-click action (see ShelfViewModel.handleCardClick).
/// A single `count: 1` tap so the click registers (and the card highlights) instantly.
///
/// Earlier this stacked a `count: 2` gesture for double-click-to-paste alongside the
/// `count: 1` select gesture. SwiftUI then has to wait the full system double-click
/// interval on every single click to rule out a second click, which showed up as a
/// visible (up to ~2s on slow double-click settings) lag before a card would highlight.
/// Double-click-to-paste is instead handled without a timed gesture: the first click
/// selects, and a click on the already-sole-selected card pastes (see
/// `ShelfViewModel.handleCardClick`), so a fast double-click still pastes with no delay.
private struct CardClickGesture: ViewModifier {
    let onClick: (NSEvent.ModifierFlags) -> Void

    func body(content: Content) -> some View {
        content.onTapGesture(count: 1) { onClick(NSEvent.modifierFlags) }
    }
}

/// The floating action pill shown on card hover (see `ItemCardView`'s top-trailing
/// overlay). Surfaces favorite and delete, the two high-value actions otherwise hidden
/// in the right-click menu, plus unpin while viewing a pinboard. Stays a quiet affordance
/// rather than a toolbar; the rest remains in the context menu and via drag.
private struct CardHoverActions: View {
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    /// Removes the card from the pinboard currently being viewed. `nil` (and so hidden)
    /// outside a pinboard, where there's nothing to unpin from.
    let onUnpin: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            IconButton(systemName: isFavorite ? "star.fill" : "star",
                       fontSize: 11, size: CGSize(width: 22, height: 22),
                       tint: isFavorite ? .yellow : .secondary,
                       help: isFavorite ? "Remove from favorites" : "Favorite",
                       action: onToggleFavorite)
            if let onUnpin {
                IconButton(systemName: "pin.slash",
                           fontSize: 11, size: CGSize(width: 22, height: 22),
                           help: "Remove from pinboard", action: onUnpin)
            }
            IconButton(systemName: "trash",
                       fontSize: 11, size: CGSize(width: 22, height: 22),
                       help: "Delete", action: onDelete)
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        )
    }
}

/// A Finder-style Quick Look preview for a file card, falling back to the generic
/// file-type icon while the thumbnail loads or when Quick Look can't render one (for
/// example, a file that has since moved off disk).
struct FileThumbnail: View {
    let item: ClipItem
    let store: ItemStore
    var compact: Bool = false
    @State private var image: NSImage?
    @State private var resolved = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: Tokens.fileType(for: item)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !resolved else { return }
            resolved = true
            image = ThumbnailCache.shared.cached(for: item)
            if image == nil,
               let url = QuickLookController.fileURLs(for: item, store: store)
                   .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                ThumbnailCache.shared.fileThumbnail(for: item, url: url) { image = $0 }
            }
        }
    }
}

struct CardThumbnail: View {
    let item: ClipItem
    let store: ItemStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            if image == nil {
                image = ThumbnailCache.shared.cached(for: item)
                if image == nil {
                    ThumbnailCache.shared.thumbnail(for: item, store: store) { image = $0 }
                }
            }
        }
    }
}
