import AppIntents
import AppKit
import CopyCore

/// Opens a fresh, read-oriented store pair for an intent invocation. Intents run
/// in-process (no separate extension) but on the system's own schedule — the app
/// may or may not already be running when one fires — so each intent opens its own
/// `DatabaseManager`/`ItemStore`/`PinboardStore` rather than reaching into a shared
/// `AppCoordinator` singleton. GRDB's `DatabasePool` is safe to open more than once
/// against the same file from the same process (SQLite's WAL mode supports multiple
/// readers), and none of these intents write to the database, so there's no risk of
/// racing the running app's writer.
private func openItemStore() throws -> ItemStore {
    let database = try DatabaseManager.makeDefault()
    let blobs = BlobStore(directory: database.blobsDirectory)
    return ItemStore(writer: database.writer, blobs: blobs)
}

private func openPinboardStore() throws -> PinboardStore {
    let database = try DatabaseManager.makeDefault()
    return PinboardStore(writer: database.writer)
}

/// Places `text` on the general pasteboard the same way the in-app "Copy Text" and
/// "Adjust Color" actions do: through `PasteService`, which tags the write with
/// Copy's self-paste marker so the clipboard monitor doesn't re-capture it as a new
/// history item.
private func placeOnPasteboard(_ text: String) {
    PasteService(pasteboard: NSPasteboard.general, keyPoster: CGKeyEventPoster())
        .place([CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))],
               plainTextOnly: false)
}

/// "Copy Latest Item" — copies the most recent history item's text to the clipboard
/// and returns it, for use as a Shortcuts action or Siri/Spotlight phrase.
struct CopyLatestItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Latest Item"
    static var description: IntentDescription? = IntentDescription(
        "Copies the most recent item from your Copy clipboard history.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try openItemStore()
        guard let text = try store.recentItems(limit: 1).first?.plainText, !text.isEmpty else {
            return .result(value: "", dialog: "Your clipboard history is empty.")
        }
        placeOnPasteboard(text)
        return .result(value: text, dialog: "Copied the latest item.")
    }
}

/// "Search Clipboard" — searches history for `query` and returns the matching items'
/// text (most recent first), copying the top match to the clipboard.
struct SearchClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Clipboard"
    static var description: IntentDescription? = IntentDescription(
        "Searches your Copy clipboard history and returns the matching text.")

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search clipboard for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let store = try openItemStore()
        let matches = try store.search(query, limit: 10).compactMap { item -> String? in
            guard let text = item.plainText, !text.isEmpty else { return nil }
            return text
        }
        guard !matches.isEmpty else {
            return .result(value: [], dialog: "No matches for \"\(query)\".")
        }
        placeOnPasteboard(matches[0])
        let count = matches.count
        return .result(value: matches, dialog: "Found \(count) matching item\(count == 1 ? "" : "s").")
    }
}

/// "Copy from Pinboard" — copies the most recently filed item's text from the named
/// pinboard to the clipboard.
struct CopyFromPinboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Item from Pinboard"
    static var description: IntentDescription? = IntentDescription(
        "Copies the most recent item from a Copy pinboard.")

    @Parameter(title: "Pinboard Name")
    var pinboard: String

    static var parameterSummary: some ParameterSummary {
        Summary("Copy latest item from \(\.$pinboard)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let pinboardStore = try openPinboardStore()
        guard let board = try pinboardStore.all().first(where: {
            $0.name.compare(pinboard, options: .caseInsensitive) == .orderedSame
        }), let boardID = board.id else {
            return .result(value: "", dialog: "No pinboard named \"\(pinboard)\".")
        }
        guard let text = try pinboardStore.items(in: boardID, limit: 1).first?.plainText, !text.isEmpty else {
            return .result(value: "", dialog: "\"\(pinboard)\" doesn't have any items yet.")
        }
        placeOnPasteboard(text)
        return .result(value: text, dialog: "Copied the latest item from \(pinboard).")
    }
}

/// Ships the three intents above as zero-setup Shortcuts actions: they appear in
/// Shortcuts.app and Spotlight as soon as Copy is installed, with Siri phrases too.
struct CopyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyLatestItemIntent(),
            phrases: [
                "Copy latest from \(.applicationName)",
                "Copy the last item in \(.applicationName)"
            ],
            shortTitle: "Copy Latest Item",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: SearchClipboardIntent(),
            phrases: [
                "Search \(.applicationName) clipboard",
                "Find in \(.applicationName)"
            ],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: CopyFromPinboardIntent(),
            phrases: [
                "Copy from pinboard in \(.applicationName)",
                "Copy pinboard item in \(.applicationName)"
            ],
            shortTitle: "Copy from Pinboard",
            systemImageName: "pin"
        )
    }
}

struct AddTextToPasteStackIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Text to Paste Stack"
    static var description: IntentDescription? = IntentDescription(
        "Requests permission to replace the Paste Stack with text items.")
    static var openAppWhenRun = true

    @Parameter(title: "Text Items")
    var texts: [String]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let delegate = NSApp.delegate as? AppDelegate,
              delegate.requestPasteStackBatch(texts) else {
            return .result(dialog: "The Paste Stack was not changed.")
        }
        return .result(dialog: "Added text to Paste Stack.")
    }
}
