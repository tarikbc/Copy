import AppKit
import ApplicationServices
import CopyCore
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// Internal drag payload identifying a `ClipItem` by uuid, used for card → tab
    /// filing drags within the shelf. Declared in project.yml's Info.plist properties
    /// (`UTExportedTypeDeclarations`) so the system recognizes it during real
    /// drag-and-drop sessions, not just as an in-process string constant.
    static let copyPinboard = UTType(exportedAs: "com.tarikbc.copy.pinboard")
    static let copyItem = UTType(exportedAs: "com.tarikbc.copy.item")
}

@MainActor
@Observable
final class ShelfViewModel {
    enum ShelfTab: Equatable {
        case history
        case pinboard(Int64)
    }

    let store: ItemStore
    let pinboardStore: PinboardStore
    /// Held so `ShelfRootView`/`ItemCardView` can read `settings.compactShelf` live —
    /// both this view model and `SettingsStore` are `@Observable`, so a body that reads
    /// `viewModel.settings.compactShelf` re-renders on toggle without any extra
    /// change-hook plumbing (the pattern `AppCoordinator` uses for AppKit-side settings
    /// like `hideDuringScreenSharing` doesn't apply here since this is pure SwiftUI).
    let settings: SettingsStore

    var items: [ClipItem] = []
    /// How many leading items in `items` are favorites; the shelf draws a divider after
    /// this many cards to separate starred copies from the rest.
    var favoritesCount = 0
    /// The faceted search: facet pill tokens + trailing free text. Driven through the
    /// mutating helpers (`updateSearchText`, `acceptSuggestion`, …) rather than a `didSet`,
    /// so a token-plus-text change refreshes once.
    var searchQuery = SearchQuery()
    /// Ranked facet suggestions for the current trailing text, and the highlighted row.
    /// `suggestionsVisible` gates the shelf's global key handler (arrows/return drive the
    /// dropdown while it's open) — see `AppCoordinator.onKeyEvent`.
    var suggestions: [Suggestion] = []
    var highlightedSuggestion = 0
    var suggestionsVisible: Bool { !suggestions.isEmpty }
    /// Mirrors the search field's focus (synced by `ShelfHeader`). The global key handler
    /// reads it to route type-to-search: a letter typed while this is false begins a search.
    var isSearchFieldFocused = false
    /// Set by the key handler to ask `ShelfHeader` to move focus into the search field;
    /// the view flips it back to false after applying.
    var focusSearchRequested = false
    /// Distinct history apps for app suggestions, loaded once per search session and
    /// cleared in `clearTransientState`.
    @ObservationIgnored private var cachedApps: [AppUsage] = []
    /// The uuid of a card to briefly flash after a "Show in History" jump (`ItemCardView`
    /// reads it). Cleared ~1s later.
    var flashItemID: String?
    /// Set by `showInHistory` before `refresh()`; consumed by `apply(_:)` once the History
    /// observation delivers the item, so the select-and-scroll happens after the card exists.
    @ObservationIgnored private var pendingJumpItemID: String?
    var tab: ShelfTab = .history {
        didSet { if tab != oldValue { refresh() } }
    }
    var pinboards: [Pinboard] = []
    var selection = ShelfSelection()
    var previewShown = false
    var editingItem: ClipItem?
    var pinboardPopoverShown = false
    var creatingItem = false
    /// Presents the keyboard-and-tips cheat sheet (reached from the drawer menu).
    var showingTips = false
    /// True while the ⌘ key is held with the shelf open; reveals the keyboard legend and
    /// the ⌘-number hints on pinboard tabs. Driven by a flags-changed monitor in
    /// `ShelfPanelController` (wired in `AppCoordinator`).
    var commandHeld = false
    /// True while ⌥ is held with the shelf open; reveals the ⌥-digit paste number on each
    /// card. Driven by the same flags-changed monitor as `commandHeld`.
    var optionHeld = false
    /// The uuid of the card the pointer is currently over, so a force-click can act on
    /// exactly the card under the cursor (set by `ItemCardView`'s hover callback).
    var hoveredItemID: String?
    /// The pinboard tab currently under an in-flight card drag, so that tab highlights.
    /// Driven by the shelf-level drop delegate (see `PinboardDropDelegate`) rather than a
    /// per-tab `.onDrop`, which never established a working drop region on the small pills.
    var reorderTargetedPinboardID: Int64?
    var reorderPlacesAfterTarget = false
    var dropTargetedPinboardID: Int64?
    /// Set by a force-click (which fires before the click's own mouse-up resolves) so the
    /// release doesn't then paste the card. Consumed by the next `handleCardClick`.
    @ObservationIgnored var suppressNextCardPaste = false
    var adjustingColorItem: ClipItem?
    /// Drives the inline, click-to-edit title field on a card (`ItemCardView`). The
    /// app-wide key monitor guard treats an active inline field exactly like the other
    /// sheets (see that guard's doc comment), so typing in it is never intercepted by
    /// the shelf's global shortcuts.
    var inlineRenamingItemID: Int64?

    /// Mirror `AppCoordinator.isPaused`/`isPasteStackActive` for the in-drawer menu
    /// (`ShelfHeader`'s ellipsis menu), which needs to show "Pause"/"Resume Monitoring"
    /// and a Paste Stack checkmark that reflect those AppKit-owned coordinator states.
    /// `AppCoordinator` pushes these live whenever the underlying state changes
    /// (`togglePause()`, `pasteStackModel.onActiveChange`), the same fan-out shape as
    /// `onCompactShelfChange` etc. keep `SettingsStore` in sync with AppKit-side state.
    var isPrivacyModeOn = false
    var isPasteStackOn = false

    /// Backs `ShelfRootView`'s permission banner. The shelf panel + its SwiftUI content
    /// are created once and reused for the app's lifetime (see
    /// `AppCoordinator.shelfController`), so this can't just be read in `.onAppear` —
    /// that would only ever reflect whatever was true the very first time the shelf
    /// ever appeared. `AppCoordinator.toggleShelf()` calls `refreshPermissionState()`
    /// right before showing the panel instead, so every open reflects live state.
    var accessibilityTrusted = AXIsProcessTrusted()

    @ObservationIgnored var onPaste: ((ClipItem, Bool) -> Void)?
    @ObservationIgnored var onPasteMultiple: ((String) -> Void)?
    @ObservationIgnored var onAddToPasteStack: ((ClipItem) -> Void)?
    @ObservationIgnored var onCopyText: ((String) -> Void)?
    /// Places one card's full representations on the clipboard. Returns whether it
    /// worked, so `copySelection` can leave the shelf open when the item is gone.
    @ObservationIgnored var onCopyItem: ((ClipItem) -> Bool)?
    @ObservationIgnored var onAdjustColorCopy: ((String) -> Void)?
    /// Opens a resolved link/file URL in its default app. `AppCoordinator` wires this to
    /// hide the shelf (restoring focus to the previous app) and hand off to NSWorkspace,
    /// matching how paste actions leave the shelf.
    @ObservationIgnored var onOpenURL: ((URL) -> Void)?

    // MARK: - Drawer-menu actions (ShelfHeader's ellipsis menu)
    //
    // Mirror the status menu's actions so the shelf is fully usable with the menu bar
    // icon hidden. `AppCoordinator` wires these to its existing action methods — the
    // same ones the status menu calls — so there's exactly one implementation of each.
    /// Fires when a modal (edit/create/color/tips) opens (`true`) or closes (`false`),
    /// so `AppCoordinator` can show/hide the centered modal child window.
    @ObservationIgnored var onModalPresent: ((Bool) -> Void)?
    @ObservationIgnored var onNewItem: (() -> Void)?
    @ObservationIgnored var onTogglePasteStack: (() -> Void)?
    @ObservationIgnored var onTogglePrivacyMode: (() -> Void)?
    @ObservationIgnored var onClearHistory: (() -> Void)?
    @ObservationIgnored var onExportHistory: (() -> Void)?
    @ObservationIgnored var onImportHistory: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// Bridged directly from `AppDelegate` (not `AppCoordinator`) — the Sparkle
    /// updater controller is owned by `AppDelegate`, not the coordinator.
    @ObservationIgnored var onCheckForUpdates: (() -> Void)?
    /// Also bridged directly from `AppDelegate`, for symmetry with `onCheckForUpdates`
    /// — `NSApp.terminate` doesn't need coordinator state, but wiring it from the same
    /// place keeps both AppDelegate-owned bridges together.
    @ObservationIgnored var onQuit: (() -> Void)?

    @ObservationIgnored private var token: ObservationToken?
    @ObservationIgnored private var pinboardsToken: ObservationToken?

    /// How many rows the active history/search query fetches. The shelf opens on one page
    /// and widens the window as scrolling approaches the oldest card (`loadMoreIfNeeded`),
    /// so browsing reaches the whole history instead of stopping at the first page. A fixed
    /// window here — not the retention setting — is what used to bound how far back the
    /// shelf could scroll.
    @ObservationIgnored private var page = PageWindow()
    /// Whether the active observation is a windowed one. The plain pinboard browse fetches
    /// every item on the board, so there's nothing to page there.
    @ObservationIgnored private var isPaged = true

    init(store: ItemStore, pinboardStore: PinboardStore, settings: SettingsStore) {
        self.store = store
        self.pinboardStore = pinboardStore
        self.settings = settings
        pinboardsToken = pinboardStore.observeAll(
            onError: { NSLog("Copy: pinboard observation failed: \($0)") },
            onChange: { [weak self] in self?.pinboards = $0 })
        refresh()
    }

    var primaryItem: ClipItem? {
        guard let uuid = selection.primary else { return nil }
        return items.first(where: { $0.uuid == uuid })
    }

    func isSelected(_ item: ClipItem) -> Bool {
        selection.selected.contains(item.uuid)
    }

    var orderedSelectedItems: [ClipItem] {
        let ordered = selection.orderedSelection(in: items.map(\.uuid))
        return ordered.compactMap { uuid in items.first(where: { $0.uuid == uuid }) }
    }

    /// Restarts the query after the search, tab, or facets changed. A new query starts back
    /// at the first page, so the window never carries over from the previous one.
    func refresh() {
        page.reset()
        previewShown = false
        startObservation()
    }

    /// Re-runs the current query with the scrolled-to window (and the preview) intact. Used
    /// after an edit that changes a row rather than the query — collapsing back to page one
    /// there would yank the shelf away from wherever the user had scrolled.
    private func reload() {
        startObservation()
    }

    private func startObservation() {
        token?.cancel()
        token = nil

        var filter = searchQuery.toFilter()
        // Scope to the active pinboard tab (AND-ed with any explicit facets).
        if case .pinboard(let id) = tab {
            filter.pinboardIDs.insert(id)
        }

        if filter.hasText {
            // Text search is one-shot (FTS); re-runs whenever the query changes.
            isPaged = true
            apply((try? store.search(filter: filter, limit: page.limit)) ?? [])
        } else if searchQuery.tokens.isEmpty, case .pinboard(let id) = tab {
            // Plain pinboard browse: keep the dedicated observation (preserves manual order).
            isPaged = false
            token = pinboardStore.observeItems(in: id,
                                               onError: { NSLog("Copy: observation failed: \($0)") },
                                               onChange: { [weak self] in self?.apply($0) })
        } else {
            // History browse or facet-only: stays live as new items are captured.
            isPaged = true
            token = store.observeRecent(filter: filter, limit: page.limit,
                                        onError: { NSLog("Copy: observation failed: \($0)") },
                                        onChange: { [weak self] in self?.apply($0) })
        }
    }

    /// Widens the fetch window as the shelf scrolls toward its oldest card, then re-runs the
    /// query against it. Each card calls this from `.onAppear`; `PageWindow` decides when a
    /// wider fetch is actually warranted (and when the history has run out).
    func loadMoreIfNeeded(at index: Int) {
        // `items` is favorites-then-recents, but the window only bounds the recents — the
        // store returns every matching favorite regardless of `limit`. Measure in
        // recents-space so a big favorites block can't read as "this page came back full"
        // and keep growing the window against an already-exhausted history. A favorite's
        // own card yields a negative index here and never trips the lookahead, which is
        // right: favorites sit at the front, nowhere near the oldest card.
        guard isPaged,
              page.growIfNeeded(visibleIndex: index - favoritesCount,
                                loadedCount: items.count - favoritesCount) else { return }
        startObservation()
    }

    // MARK: Smart search

    /// Sets the trailing free text and recomputes suggestions + results. Bound to the token
    /// field's `TextField`.
    func updateSearchText(_ text: String) {
        let wasEmpty = searchQuery.text.isEmpty
        searchQuery.text = text
        // Refresh the app list at the start of each search so a just-copied app appears.
        if wasEmpty, !text.isEmpty {
            cachedApps = (try? store.distinctApps()) ?? []
        }
        recomputeSuggestions()
        refresh()
    }

    /// Commits a suggestion as a pill, clearing the typed prefix.
    func acceptSuggestion(_ suggestion: Suggestion) {
        searchQuery.add(suggestion.token)
        searchQuery.text = ""
        suggestions = []
        refresh()
    }

    func acceptHighlightedSuggestion() {
        guard suggestions.indices.contains(highlightedSuggestion) else { return }
        acceptSuggestion(suggestions[highlightedSuggestion])
    }

    func moveSuggestion(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlightedSuggestion = (highlightedSuggestion + delta + suggestions.count) % suggestions.count
    }

    /// Hides the dropdown without changing the query (Escape). It reappears on the next
    /// keystroke.
    func dismissSuggestions() {
        suggestions = []
    }

    /// Backspace on an empty field removes the last pill.
    func removeLastToken() {
        guard searchQuery.text.isEmpty, !searchQuery.tokens.isEmpty else { return }
        searchQuery.removeLast()
        recomputeSuggestions()
        refresh()
    }

    func removeToken(_ token: SearchToken) {
        searchQuery.remove(token)
        recomputeSuggestions()
        refresh()
    }

    func clearSearch() {
        searchQuery = SearchQuery()
        suggestions = []
        refresh()
    }

    /// "Show in History": clears the search, switches to the History tab, and (once the
    /// observation delivers) selects the item so the existing scroll-to animation centers
    /// on it, with a brief flash. Only reaches items within the recent History window.
    func showInHistory(_ item: ClipItem) {
        searchQuery = SearchQuery()
        suggestions = []
        pendingJumpItemID = item.uuid
        if tab != .history {
            tab = .history          // didSet → refresh()
        } else {
            refresh()
        }
    }

    private func flashItem(_ uuid: String) {
        flashItemID = uuid
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            if self?.flashItemID == uuid { self?.flashItemID = nil }
        }
    }

    private func recomputeSuggestions() {
        // Guarantee the app list is loaded before matching (the search-start reload can be
        // missed, e.g. if the field wasn't empty first), so app suggestions always appear.
        if cachedApps.isEmpty {
            cachedApps = (try? store.distinctApps()) ?? []
        }
        suggestions = searchSuggestions(prefix: searchQuery.text, apps: cachedApps,
                                        pinboards: pinboards, query: searchQuery)
        highlightedSuggestion = 0
    }

    /// Reset search/selection when the shelf closes. Anchors selection to the newest
    /// item rather than clearing it, since `show()` doesn't re-run `apply(_:)` on
    /// reopen — leaving the selection empty here would otherwise leave ⏎/Space dead
    /// until the user first pressed an arrow key.
    func clearTransientState() {
        previewShown = false
        if let first = items.first { selection.click(first.uuid) } else { selection.reset() }
        editingItem = nil
        creatingItem = false
        adjustingColorItem = nil
        inlineRenamingItemID = nil
        showingTips = false
        commandHeld = false
        hoveredItemID = nil
        if !searchQuery.isEmpty { searchQuery = SearchQuery() }
        suggestions = []
        cachedApps = []
        isSearchFieldFocused = false
        focusSearchRequested = false
    }

    /// Called by `AppCoordinator.toggleShelf()` right before showing the panel — see
    /// the `accessibilityTrusted` doc comment for why a one-time `.onAppear` read isn't
    /// enough.
    func refreshPermissionState() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Shift/⌘-click always extend the multi-selection, regardless of
    /// `settings.doubleClickToPaste`. A plain click either selects-and-pastes (today's
    /// behavior) or just selects, leaving the paste to `handleCardDoubleClick`/⏎ — see
    /// that setting's doc comment in `SettingsStore`.
    func handleCardClick(_ item: ClipItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            selection.shiftClick(item.uuid, in: items.map(\.uuid))
        } else if modifiers.contains(.command) {
            selection.commandClick(item.uuid, in: items.map(\.uuid))
        } else {
            // A force-click already acted on this card (preview/editor) before this
            // release resolved; consume the guard so the release only selects, never
            // pastes.
            if suppressNextCardPaste {
                suppressNextCardPaste = false
                selection.click(item.uuid)
                return
            }
            // Paste immediately on a single click when two-click-to-paste is off. When
            // it's on, paste only if this card was ALREADY the sole selection before this
            // click, i.e. this is the second click on an already-highlighted card. That
            // keeps a fast double-click pasting (first click selects, second pastes) while
            // the first click always highlights instantly, with no double-click-timeout
            // wait (see `CardClickGesture`).
            let wasSoleSelection = selection.primary == item.uuid && selection.selected.count == 1
            let pasteNow = !settings.doubleClickToPaste || wasSoleSelection
            selection.click(item.uuid)
            if pasteNow {
                requestPaste(item, plain: false)
            }
        }
    }

    func moveSelection(_ delta: Int) {
        selection.move(delta, in: items.map(\.uuid))
    }

    func requestPaste(_ item: ClipItem, plain: Bool) {
        onPaste?(item, plain)
    }

    /// Opens the primary selection's link or file in its default app without pasting
    /// (⌘O). No-ops with a gentle HUD for items that have nothing to open.
    func openSelected() {
        guard let item = primaryItem else { return }
        open(item)
    }

    /// Opens a specific item's link or file (the card context menu's "Open"). Hides the
    /// shelf via `onOpenURL` (set by `AppCoordinator`); shows a HUD when the item has no
    /// openable target so the shortcut never feels silently dead.
    func open(_ item: ClipItem) {
        guard let url = openableURL(for: item) else {
            HUD.show("Nothing to open")
            return
        }
        onOpenURL?(url)
    }

    /// The link/file an item can open, or nil. Links open their URL; files open the
    /// first representation still on disk; a plain-text item is openable only when it is
    /// itself an http(s) URL. Other kinds (image, color, non-URL text) return nil.
    private func openableURL(for item: ClipItem) -> URL? {
        switch item.kind {
        case .link:
            return webURL(from: item.plainText)
        case .file:
            return QuickLookController.fileURLs(for: item, store: store)
                .first { FileManager.default.fileExists(atPath: $0.path) }
        case .text, .richText:
            return webURL(from: item.plainText)
        case .image, .color:
            return nil
        }
    }

    private func webURL(from text: String?) -> URL? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Rotates an image item 90 degrees (clockwise or counter-clockwise) in place,
    /// re-encoding as PNG, refreshing its thumbnail, and re-rendering the shelf.
    func rotateImage(_ item: ClipItem, clockwise: Bool) {
        guard item.kind == .image, let id = item.id else { return }
        do {
            let reps = try store.representations(forItemID: id)
            guard let imageData = reps.first(where: { NSImage(data: $0.data) != nil })?.data,
                  let rotated = ImageRotation.rotated(imageData, clockwise: clockwise) else {
                HUD.show("Couldn't rotate that")
                return
            }
            try store.replaceImageRepresentation(itemID: id, data: rotated, uti: "public.png")
            ThumbnailCache.shared.invalidate(for: item)
            reload()
        } catch {
            NSLog("Copy: image rotate failed: \(error)")
            HUD.show("Couldn't rotate that")
        }
    }

    /// ⌘C's mirror of `pasteSelection`, and it has to be a mirror: ⌘V and ⌘⌫ both act on
    /// the whole selection, so a ⌘C that silently copied only the primary card would be
    /// the one multi-select gesture that quietly did something else. One card copies its
    /// full representations; several copy their joined text, because the pasteboard holds
    /// one item at a time. Returns whether the caller should close the shelf.
    func copySelection() -> Bool {
        let picked = orderedSelectedItems
        if picked.count <= 1 {
            guard let item = picked.first ?? primaryItem else { return false }
            return onCopyItem?(item) ?? false
        }
        let filtered = picked.filter { isEditableKind($0.kind) || $0.kind == .color }
        guard !filtered.isEmpty else {
            HUD.show("No text in selection")
            return false
        }
        if filtered.count == 1 { return onCopyItem?(filtered[0]) ?? false }
        onCopyText?(filtered.map { $0.plainText ?? "" }.joined(separator: "\n"))
        return true
    }

    func pasteSelection(plain: Bool) {
        let picked = orderedSelectedItems
        if picked.count <= 1 {
            if let item = picked.first ?? primaryItem { requestPaste(item, plain: plain) }
            return
        }
        let filtered = picked.filter { isEditableKind($0.kind) || $0.kind == .color }
        guard !filtered.isEmpty else {
            HUD.show("No text in selection")
            return
        }
        if filtered.count == 1 {
            requestPaste(filtered[0], plain: plain)
            return
        }
        let joined = filtered.map { $0.plainText ?? "" }.joined(separator: "\n")
        onPasteMultiple?(joined)
    }

    func deleteSelection() {
        var snapshots: [DeletedSnapshot] = []
        for item in orderedSelectedItems {
            guard let id = item.id else { continue }
            let snapshot = undoSnapshot(for: item)
            do {
                try store.delete(itemID: id)
                if let snapshot { snapshots.append(snapshot) }
            } catch {
                NSLog("Copy: failed to delete item: \(error)")
                HUD.show("Couldn't complete that")
            }
        }
        if !snapshots.isEmpty { pushUndo(.deleted(snapshots)) }
        if !searchQuery.isEmpty { refresh() }
    }

    func toggleFavoritePrimary() {
        guard let item = primaryItem, let id = item.id else { return }
        do {
            try store.setFavorite(itemID: id, !item.isFavorite)
        } catch {
            NSLog("Copy: failed to toggle favorite: \(error)")
            HUD.show("Couldn't complete that")
        }
        if !searchQuery.isEmpty { refresh() }
    }

    func addSelection(toPinboard id: Int64) {
        for item in orderedSelectedItems {
            guard let itemID = item.id else { continue }
            do {
                try pinboardStore.add(itemID: itemID, to: id)
            } catch {
                NSLog("Copy: failed to add item to pinboard: \(error)")
                HUD.show("Couldn't complete that")
            }
        }
    }

    // MARK: - Per-item actions (context menu)

    func addToPasteStack(_ item: ClipItem) {
        onAddToPasteStack?(item)
    }

    /// Places `item`'s recognized OCR text on the clipboard, marked as a self-paste —
    /// a plain copy, not a paste-in-place, since the user asked to copy the text, not
    /// paste it. No-ops if the item has no recognized text.
    func copyText(_ item: ClipItem) {
        guard let text = item.recognizedText, !text.isEmpty else { return }
        onCopyText?(text)
    }

    /// Opens the system Quick Look panel for a `.file` item's underlying file(s), read
    /// straight from its `public.file-url` representations. No-ops if none of those
    /// files still exist on disk (e.g. the source was moved or deleted since copying).
    func quickLook(_ item: ClipItem) {
        QuickLookController.shared.preview(QuickLookController.fileURLs(for: item, store: store))
    }

    func delete(_ item: ClipItem) {
        guard let id = item.id else { return }
        let snapshot = undoSnapshot(for: item)
        do {
            try store.delete(itemID: id)
            if let snapshot { pushUndo(.deleted([snapshot])) }
        } catch {
            NSLog("Copy: failed to delete item: \(error)")
            HUD.show("Couldn't complete that")
        }
        if !searchQuery.isEmpty { refresh() }
    }

    func toggleFavorite(_ item: ClipItem) {
        guard let id = item.id else { return }
        do {
            try store.setFavorite(itemID: id, !item.isFavorite)
        } catch {
            NSLog("Copy: failed to toggle favorite: \(error)")
            HUD.show("Couldn't complete that")
        }
        if !searchQuery.isEmpty { refresh() }
    }

    // MARK: - Pinboard actions passthrough

    func createPinboard(name: String, symbol: String, emoji: String? = nil, tint: String = "") {
        do {
            try pinboardStore.create(name: name, symbol: symbol, emoji: emoji, tint: tint)
        } catch {
            NSLog("Copy: failed to create pinboard: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func renamePinboard(id: Int64, to name: String) {
        do {
            try pinboardStore.rename(id: id, to: name)
        } catch {
            NSLog("Copy: failed to rename pinboard: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func setPinboardSymbol(id: Int64, _ symbol: String) {
        do {
            try pinboardStore.setSymbol(id: id, symbol)
        } catch {
            NSLog("Copy: failed to set pinboard symbol: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func setPinboardEmoji(id: Int64, _ emoji: String?) {
        do {
            try pinboardStore.setEmoji(id: id, emoji)
        } catch {
            NSLog("Copy: failed to set pinboard emoji: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func setPinboardTint(id: Int64, _ tint: String) {
        do {
            try pinboardStore.setTint(id: id, tint)
        } catch {
            NSLog("Copy: failed to set pinboard tint: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func deletePinboard(id: Int64) {
        do {
            try pinboardStore.delete(id: id)
            if tab == .pinboard(id) { tab = .history }
        } catch {
            NSLog("Copy: failed to delete pinboard: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func movePinboard(id: Int64, relativeTo targetID: Int64, placeAfterTarget: Bool) {
        do {
            // Apply the returned order immediately; the observation then keeps every
            // other consumer in sync with the same persisted database order.
            pinboards = try pinboardStore.move(
                id: id,
                relativeTo: targetID,
                placeAfterTarget: placeAfterTarget
            )
        } catch {
            NSLog("Copy: failed to reorder pinboards: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func addItem(_ item: ClipItem, toPinboard id: Int64) {
        guard let itemID = item.id else { return }
        do {
            try pinboardStore.add(itemID: itemID, to: id)
        } catch {
            NSLog("Copy: failed to add item to pinboard: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    func removeItem(_ item: ClipItem, fromPinboard id: Int64) {
        guard let itemID = item.id else { return }
        do {
            try pinboardStore.remove(itemID: itemID, from: id)
            pushUndo(.removedFromPinboard(itemID: itemID, pinboardID: id))
        } catch {
            NSLog("Copy: failed to remove item from pinboard: \(error)")
            HUD.show("Couldn't complete that")
        }
    }

    // MARK: - Undo (session-only, bounded)
    //
    // A small LIFO stack that reverses the destructive shelf actions that are cheap to
    // capture: a delete (re-insert the archived item + its pinboard memberships) and a
    // remove-from-pinboard (re-add the membership). ⌘Z pops the top entry. Not persisted
    // across launches by design.

    private struct DeletedSnapshot {
        let archived: ArchivedItem
        let pinboardIDs: Set<Int64>
    }

    private enum UndoAction {
        case deleted([DeletedSnapshot])
        case removedFromPinboard(itemID: Int64, pinboardID: Int64)
    }

    @ObservationIgnored private var undoStack: [UndoAction] = []
    private static let undoLimit = 25

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// Captures everything needed to re-create an item (its archive bytes + which
    /// pinboards it belonged to) before it is deleted. Returns nil if the snapshot can't
    /// be taken, in which case the delete simply isn't undoable rather than blocked.
    private func undoSnapshot(for item: ClipItem) -> DeletedSnapshot? {
        guard let id = item.id else { return nil }
        do {
            let archived = try store.archivedSnapshot(itemID: id)
            let boards = (try? pinboardStore.pinboardIDs(forItemID: id)) ?? []
            return DeletedSnapshot(archived: archived, pinboardIDs: boards)
        } catch {
            NSLog("Copy: undo snapshot failed: \(error)")
            return nil
        }
    }

    func undoLast() {
        guard let action = undoStack.popLast() else {
            HUD.show("Nothing to undo")
            return
        }
        do {
            switch action {
            case .deleted(let snapshots):
                for snapshot in snapshots {
                    _ = try store.importArchived(snapshot.archived)
                    // Resolve the re-inserted (or pre-existing, if the same content was
                    // re-copied since) item by content hash to restore its memberships.
                    if let restored = try store.item(contentHash: snapshot.archived.contentHash),
                       let restoredID = restored.id {
                        for board in snapshot.pinboardIDs {
                            try pinboardStore.add(itemID: restoredID, to: board)
                        }
                    }
                }
                HUD.show(snapshots.count == 1 ? "Restored" : "Restored \(snapshots.count) items")
            case .removedFromPinboard(let itemID, let pinboardID):
                try pinboardStore.add(itemID: itemID, to: pinboardID)
                HUD.show("Restored to pinboard")
            }
            reload()
        } catch {
            NSLog("Copy: undo failed: \(error)")
            HUD.show("Couldn't undo that")
        }
    }

    /// Looks up an item by uuid for a card→tab drop. `items` only holds the current
    /// tab/search's rows, which may exclude the dragged item (e.g. dropping a History
    /// card onto a different pinboard tab), so this falls back to a broader store scan.
    func item(forUUID uuid: String) -> ClipItem? {
        if let match = items.first(where: { $0.uuid == uuid }) { return match }
        return (try? store.recentItems(limit: 1_000))?.first(where: { $0.uuid == uuid })
    }

    /// Handles a card (or a whole multi-selection) dropped onto a pinboard tab.
    /// `uuids` is one uuid for a single-card drag, or the ordered selection's uuids
    /// for a multi-selection drag (see `ShelfViewModel.multiDragProvider()`).
    func dropItems(uuids: [String], toPinboard pinboard: Pinboard) {
        guard let id = pinboard.id else { return }
        var added = 0
        for uuid in uuids {
            guard let item = item(forUUID: uuid), let itemID = item.id else { continue }
            do {
                try pinboardStore.add(itemID: itemID, to: id)
                added += 1
            } catch {
                NSLog("Copy: failed to add item to pinboard: \(error)")
            }
        }
        switch added {
        case 0: HUD.show("Couldn't complete that")
        case 1: HUD.show("Added to \(pinboard.name)")
        default: HUD.show("Added \(added) items to \(pinboard.name)")
        }
    }

    /// Called from a card's "Edit…" context menu item (with that card's item) and the
    /// ⌘E shortcut (parameterless, targets the primary selection). No-ops for kinds
    /// `EditItemSheet` can't meaningfully edit (mirrors `ItemCardView.isEditable`).
    func beginEdit(_ item: ClipItem? = nil) {
        guard let target = item ?? primaryItem, isEditableKind(target.kind) else { return }
        editingItem = target
    }

    /// Saves edited rich text from `EditItemSheet`, then dismisses it either way. RTF
    /// encoding happens here (the app layer) rather than in CopyCore, which stays
    /// Foundation-only and takes pre-encoded `Data` — see `ItemStore.replaceContent(itemID:rtfData:plainText:)`.
    func commitEdit(attributed: NSAttributedString) {
        defer { editingItem = nil }
        guard let item = editingItem, let id = item.id else { return }
        let plainText = attributed.string
        guard let rtfData = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        ) else {
            NSLog("Copy: failed to RTF-encode edited item")
            HUD.show("Couldn't save changes")
            return
        }
        do {
            try store.replaceContent(itemID: id, rtfData: rtfData, plainText: plainText)
        } catch {
            NSLog("Copy: failed to save edited item: \(error)")
            HUD.show("Couldn't save changes")
        }
    }

    /// Opens `CreateItemSheet` from ⌘N or the status menu's "New Item…" action.
    func beginCreate() {
        creatingItem = true
    }

    /// Creates a user-authored text item from `CreateItemSheet`, then dismisses it
    /// either way.
    func commitCreate(text: String, title: String?) {
        defer { creatingItem = false }
        do {
            try store.createTextItem(text, title: title?.isEmpty == true ? nil : title)
        } catch {
            NSLog("Copy: failed to create item: \(error)")
            HUD.show("Couldn't create item")
        }
    }

    /// Begins inline (click-to-edit) rename of `item`'s title in place on its card —
    /// the primary rename entry point (title tap, context-menu "Rename…", and ⌘R all
    /// route here). The app-wide key monitor guard in `AppCoordinator` gates on this
    /// state so typing in the field is never intercepted by the shelf's shortcuts.
    func beginInlineRename(_ item: ClipItem) {
        inlineRenamingItemID = item.id
    }

    /// Saves a new title from the inline title field, then clears inline-rename state
    /// either way — but only if it still points at `item`. A stale commit can arrive
    /// here after `inlineRenamingItemID` has already moved on to a different card (see
    /// `InlineTitleField`'s `.onDisappear`, which commits the outgoing card's edit
    /// when the user starts renaming a new one before the old one resolved); clearing
    /// unconditionally would stomp the new card's rename session back to nil right
    /// after it started. An empty title clears the custom title, reverting to the
    /// auto title.
    func commitInlineRename(_ item: ClipItem, to title: String) {
        defer { if inlineRenamingItemID == item.id { inlineRenamingItemID = nil } }
        saveTitle(item, to: title)
    }

    /// Cancels an in-progress inline rename without saving (Escape).
    func cancelInlineRename() {
        inlineRenamingItemID = nil
    }

    private func saveTitle(_ item: ClipItem, to title: String) {
        guard let id = item.id else { return }
        do {
            try store.setTitle(itemID: id, title.isEmpty ? nil : title)
        } catch {
            NSLog("Copy: failed to rename item: \(error)")
            HUD.show("Couldn't rename item")
        }
        if !searchQuery.isEmpty { refresh() }
    }

    /// Opens `ColorAdjustSheet` from a color card's "Adjust Color…" context menu item,
    /// seeded with the item's current hex. No-ops for non-color items.
    func beginAdjustColor(_ item: ClipItem) {
        guard item.kind == .color else { return }
        adjustingColorItem = item
    }

    /// Places the tweaked color (as a hex string) via the coordinator's
    /// `onAdjustColorCopy` hook, then dismisses the sheet either way. Does not mutate
    /// the stored item — this is a re-copy with a tweak, not an edit.
    func commitAdjustColor(_ hex: String) {
        defer { adjustingColorItem = nil }
        onAdjustColorCopy?(hex)
    }

    private func isEditableKind(_ kind: ItemKind) -> Bool {
        switch kind {
        case .text, .richText, .link: return true
        case .image, .file, .color: return false
        }
    }

    private func apply(_ new: [ClipItem]) {
        // Favorites float to the front (preserving recency within each group); the shelf
        // draws a divider at the boundary (`favoritesCount`).
        let favorites = new.filter(\.isFavorite)
        let rest = new.filter { !$0.isFavorite }
        items = favorites + rest
        favoritesCount = favorites.count
        let order = items.map(\.uuid)
        selection.prune(existing: Set(order), order: order)
        if let jump = pendingJumpItemID {
            pendingJumpItemID = nil
            if order.contains(jump) {
                selection.click(jump)   // sets primary → ShelfRootView's onChange animates the scroll
                flashItem(jump)
                return
            }
        }
        if selection.selected.isEmpty, let first = items.first { selection.click(first.uuid) }
    }

    /// Builds the drag payload for a card: its native representations (so dragging out
    /// to other apps still works) plus an internal uuid representation (so dropping on
    /// a pinboard tab can resolve it back to a `ClipItem` via `item(forUUID:)`).
    ///
    /// When the dragged card is part of a multi-selection (more than one card
    /// selected), the WHOLE ordered selection drags together instead of just this
    /// card — see `multiDragProvider()`. Dragging a card that ISN'T in the current
    /// selection (or when only one card is selected) keeps today's single-item
    /// behavior unchanged.
    func dragProvider(for item: ClipItem) -> NSItemProvider {
        if selection.selected.contains(item.uuid), selection.selected.count > 1 {
            return multiDragProvider()
        }
        let provider = contentProvider(for: item)
        let uuid = item.uuid
        provider.registerDataRepresentation(forTypeIdentifier: UTType.copyItem.identifier, visibility: .all) { completion in
            completion(Data(uuid.utf8), nil)
            return nil
        }
        return provider
    }

    /// One `NSItemProvider` for the whole ordered selection. SwiftUI's `.onDrag(_:)`
    /// returns exactly one `NSItemProvider` on macOS 14 — there's no multi-provider
    /// drag session until later SDKs, and a true per-item multi-drag would mean
    /// replacing this whole drag path (and the pinboard-filing drop it feeds) with an
    /// AppKit `NSDraggingSession`/`NSDraggingSource` rework. The pragmatic,
    /// macOS-14-safe answer: one provider whose text representation is every selected
    /// item's plain text, newline-joined in visible order, so dropping it into any
    /// text-accepting app (TextEdit, a browser field, Notes...) drops all selected
    /// items together. It also carries every selected uuid (newline-joined) under the
    /// internal `copyItem` type, so dropping the whole selection onto a pinboard tab
    /// files all of them — see `ShelfRootView`'s pinboard `.onDrop` and `dropItems(uuids:toPinboard:)`.
    private func multiDragProvider() -> NSItemProvider {
        let selected = orderedSelectedItems
        let joinedText = selected.map { $0.plainText ?? "" }.joined(separator: "\n")
        let provider = NSItemProvider(object: joinedText as NSString)
        let uuids = selected.map(\.uuid).joined(separator: "\n")
        provider.registerDataRepresentation(forTypeIdentifier: UTType.copyItem.identifier, visibility: .all) { completion in
            completion(Data(uuids.utf8), nil)
            return nil
        }
        return provider
    }

    private func contentProvider(for item: ClipItem) -> NSItemProvider {
        guard let id = item.id, let reps = try? store.representations(forItemID: id) else {
            return NSItemProvider()
        }
        if let urlRep = reps.first(where: { $0.uti == "public.file-url" }),
           let url = URL(dataRepresentation: urlRep.data, relativeTo: nil) {
            return NSItemProvider(object: url as NSURL)
        }
        if item.kind == .image,
           let rep = reps.first(where: { $0.uti == "public.png" }) ?? reps.first(where: { $0.uti == "public.tiff" }) {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: rep.uti, visibility: .all) { completion in
                completion(rep.data, nil)
                return nil
            }
            return provider
        }
        if item.kind == .link, let url = URL(string: item.plainText ?? "") {
            return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: (item.plainText ?? "") as NSString)
    }
}
