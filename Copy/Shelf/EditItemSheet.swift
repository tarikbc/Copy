import SwiftUI
import CopyCore

/// Edit-in-place sheet for a card's "Edit…" menu item and ⌘E: a rich text editor
/// (Bold/Italic/Underline/Strikethrough) with live character/word/line stats. Saving
/// writes an updated `public.rtf` representation alongside plain text — plain stays
/// canonical for "Paste as plain text" and search, rich is the alternate for a
/// formatted paste.
struct EditItemSheet: View {
    let item: ClipItem
    let store: ItemStore
    let onCancel: () -> Void
    let onSave: (NSAttributedString) -> Void

    @State private var attributedText: NSAttributedString
    @State private var original: NSAttributedString
    @StateObject private var editorController = RichTextEditorController()

    init(item: ClipItem, store: ItemStore, initialRTF: Data? = nil,
         onCancel: @escaping () -> Void, onSave: @escaping (NSAttributedString) -> Void) {
        self.item = item
        self.store = store
        self.onCancel = onCancel
        self.onSave = onSave
        let seeded = initialRTF.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
            ?? Self.seedAttributedText(item: item, store: store)
        _attributedText = State(initialValue: seeded)
        _original = State(initialValue: seeded)
    }

    /// Seeds from the item's existing `public.rtf` representation when there is one
    /// (Copy captures RTF alongside plain text for rich-text copies), so re-editing a
    /// previously-formatted item doesn't flatten it back to plain text. Falls back to
    /// plain text for items that never had an RTF representation (or whose RTF fails to
    /// decode).
    private static func seedAttributedText(item: ClipItem, store: ItemStore) -> NSAttributedString {
        if let id = item.id,
           let reps = try? store.representations(forItemID: id),
           let rtfRep = reps.first(where: { $0.uti == "public.rtf" }),
           let decoded = NSAttributedString(rtf: rtfRep.data, documentAttributes: nil) {
            return decoded
        }
        // Plain-text items carry no attributes; give them an explicit system font and the
        // adaptive label color so the editor renders clean, readable text (an unattributed
        // string otherwise falls back to NSTextView's default, a small serif) rather than
        // the cramped look it had before.
        return NSAttributedString(string: item.plainText ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private var isUnchanged: Bool {
        attributedText == original
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // Fills the middle edge-to-edge between the dividers; the text view keeps its
            // own opaque `.textBackgroundColor` fill so the content region reads as a
            // distinct, legible surface against the glass toolbar and footer.
            RichTextEditor(attributedText: $attributedText, controller: editorController)
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
        .glassSurface(cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Cancel on the left, the B/I/U/S formatting group centered, Save (prominent) on the
    /// right — the standard editor-toolbar hierarchy.
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            formattingGroup
            Spacer(minLength: 8)
            Button("Save") { onSave(attributedText) }
                .buttonStyle(.borderedProminent)
                // ⌘Return saves: a plain Return inserts a newline in the editor, so the
                // default-action Return can't reach the Save button while typing.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isUnchanged)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A grouped B/I/U/S control (Bold/Italic/Underline get their ⌘ shortcuts;
    /// Strikethrough has no system-standard one, so it's click-only). The soft grouped
    /// background reads as one segmented control rather than four loose icons.
    private var formattingGroup: some View {
        HStack(spacing: 2) {
            FormatButton(symbol: "bold", label: "Bold", shortcut: "b", isActive: editorController.isBoldActive) {
                editorController.toggleBold()
            }
            FormatButton(symbol: "italic", label: "Italic", shortcut: "i", isActive: editorController.isItalicActive) {
                editorController.toggleItalic()
            }
            FormatButton(symbol: "underline", label: "Underline", shortcut: "u", isActive: editorController.isUnderlineActive) {
                editorController.toggleUnderline()
            }
            FormatButton(symbol: "strikethrough", label: "Strikethrough", isActive: editorController.isStrikethroughActive) {
                editorController.toggleStrikethrough()
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(statsText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                KeyHint(key: "⌘B", label: "Bold")
                KeyHint(key: "⌘I", label: "Italic")
                KeyHint(key: "⌘U", label: "Underline")
                KeyHint(key: "⌘↩", label: "Save")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statsText: String {
        let c = editorController.characterCount
        let w = editorController.wordCount
        let l = editorController.lineCount
        let characters = "\(c) \(c == 1 ? "character" : "characters")"
        let words = "\(w) \(w == 1 ? "word" : "words")"
        let lines = "\(l) \(l == 1 ? "line" : "lines")"
        return "\(characters) · \(words) · \(lines)"
    }
}

/// A single quiet toolbar button: SF Symbol only, no border — matches the shelf's
/// existing icon-button language (e.g. `DrawerMenu`'s ellipsis button) rather than
/// introducing a new, louder toolbar style. When `isActive` (the current selection/
/// typing attributes already carry this attribute), the icon tints to `accentColor`
/// over a soft accent-opacity fill — the same quiet selection language `SymbolSwatch`/
/// `EmojiSwatch` already use elsewhere, just at low opacity instead of a solid fill so
/// the row stays a clean B/I/U/S strip rather than a row of filled buttons.
private struct FormatButton: View {
    let symbol: String
    let label: String
    var shortcut: KeyEquivalent?
    var isActive: Bool = false
    let action: () -> Void

    init(symbol: String, label: String, shortcut: KeyEquivalent? = nil, isActive: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.shortcut = shortcut
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Group {
            if let shortcut {
                button.keyboardShortcut(shortcut, modifiers: .command)
            } else {
                button
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.white : .secondary)
                .frame(width: 32, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.accentColor : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
