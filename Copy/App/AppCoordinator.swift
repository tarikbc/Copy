import AppKit
import ApplicationServices
import CopyCore
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppCoordinator {
    let store: ItemStore
    let pinboardStore: PinboardStore
    let settings: SettingsStore
    private let monitor: ClipboardMonitor
    private let pasteService: PasteService
    private let persistQueue = DispatchQueue(label: "com.tarikbc.copy.persist", qos: .utility)
    private let saveErrors = SaveErrorReporter()
    private var retentionTimer: DispatchSourceTimer?
    private(set) var isPaused = false
    /// True in a DEBUG build when the demo-mode flag is set (toggled from the status menu):
    /// runs against an isolated, reseeded demo database with curated mock data, and never
    /// starts clipboard capture. Always false in release. See `DemoData`.
    let isDemoMode: Bool
    /// `UserDefaults` key the status-menu toggle flips; read at launch to enter demo mode.
    static let demoModeKey = "demoMode"
    private(set) lazy var shelfViewModel = ShelfViewModel(store: store, pinboardStore: pinboardStore, settings: settings)
    private(set) lazy var linkFetcher = LinkMetadataFetcher(store: store)
    private(set) lazy var ocrController = OCRController(store: store)
    private(set) lazy var archiveController = ArchiveController(store: store, pinboardStore: pinboardStore)

    /// Assigned eagerly in `init()` (from a local, not `self.pasteStackModel`) so the
    /// monitor's `onCapture` closure can capture it directly for the auto-enqueue-while-
    /// active behavior — `self` isn't fully initialized yet at that point in `init()`,
    /// but a plain local reference to this same instance is fine to capture. Its
    /// `onActiveChange` handler is wired afterward, once `self` is safe to capture.
    private let pasteStackModel: PasteStackModel
    private lazy var pasteStackController = PasteStackController(
        model: pasteStackModel,
        hideDuringScreenSharing: settings.hideDuringScreenSharing,
        proDark: settings.shelfProDark)
    private lazy var pasteStackEngine = PasteStackEngine(onIntercept: { [weak self] in
        self?.pasteNextViaEngine()
    })

    /// How often the retention pruner re-runs while the app stays open.
    private static let retentionInterval: TimeInterval = 12 * 60 * 60

    /// The always-present SwiftUI host for the centered modal content (edit/create/color/
    /// tips); shown in a child window by `ShelfPanelController.presentModal` when a modal
    /// opens (driven by `shelfViewModel.onModalPresent`).
    private lazy var modalHostView: NSView = NSHostingView(rootView: ShelfModalHostView(viewModel: shelfViewModel))

    private lazy var shelfController: ShelfPanelController = {
        let controller = ShelfPanelController(
            hideDuringScreenSharing: settings.hideDuringScreenSharing,
            compactShelf: settings.compactShelf,
            proDark: settings.shelfProDark) { [weak self] in
            guard let self else { return NSView() }
            return NSHostingView(rootView: ShelfRootView(viewModel: self.shelfViewModel))
        }
        controller.onDidHide = { [weak self] in
            self?.shelfViewModel.clearTransientState()
        }
        controller.onKeyEvent = { [weak self, weak controller] event in
            guard let self, let controller else { return false }
            let viewModel = self.shelfViewModel
            // While the edit/create/rename/adjust-color sheet — or an inline title
            // rename field — is up, let its own view handle every key (arrows, space,
            // escape, return) instead of the shelf's global shortcuts — this monitor is
            // app-wide and fires before the sheet's/field's responder chain would see
            // the event otherwise.
            guard viewModel.editingItem == nil, !viewModel.pinboardPopoverShown,
                  !viewModel.creatingItem, !viewModel.showingTips,
                  viewModel.adjustingColorItem == nil,
                  viewModel.inlineRenamingItemID == nil else { return false }
            // Type-to-search: the search field isn't auto-focused, so a letter typed while
            // browsing begins a search and moves focus into the field.
            if !viewModel.isSearchFieldFocused,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let first = chars.first, first.isLetter {
                viewModel.updateSearchText(viewModel.searchQuery.text + (event.characters ?? chars))
                viewModel.focusSearchRequested = true
                return true
            }
            // Smart-search dropdown: while it's open its keys drive the dropdown, not the
            // cards. Backspace on an empty field removes the last pill (dropdown open or not).
            if viewModel.suggestionsVisible {
                switch event.keyCode {
                case 125: viewModel.moveSuggestion(by: 1); return true   // down
                case 126: viewModel.moveSuggestion(by: -1); return true  // up
                case 36, 48: viewModel.acceptHighlightedSuggestion(); return true  // return / tab
                case 53: viewModel.dismissSuggestions(); return true     // escape closes the dropdown
                default: break
                }
            }
            if event.keyCode == 51,
               viewModel.searchQuery.text.isEmpty, !viewModel.searchQuery.tokens.isEmpty {
                viewModel.removeLastToken()
                return true
            }
            // ⌘1 → history tab, ⌘2...⌘9 → nth pinboard. Checked before keyCode routing
            // so the digit keys never fall through to other handlers.
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let digit = chars.first, let digitValue = digit.wholeNumberValue,
               (1...9).contains(digitValue) {
                if digitValue == 1 {
                    viewModel.tab = .history
                } else {
                    let index = digitValue - 2
                    if viewModel.pinboards.indices.contains(index), let id = viewModel.pinboards[index].id {
                        viewModel.tab = .pinboard(id)
                    }
                }
                return true
            }
            // ⌥-digit 1-9 pastes the Nth visible card directly. It's on Option (not a bare
            // digit) so plain numbers type into the always-focused search field; holding
            // Option reveals the paste number on each card (`optionHeld`). ⌘-digit tab
            // switching is handled above and returns before here, so it never collides.
            let allowsDigitQuickPaste = event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.control)
            let pasteVisible: (Int) -> Void = { index in
                guard viewModel.items.indices.contains(index) else { return }
                viewModel.requestPaste(viewModel.items[index], plain: false)
            }
            // Ignore caps lock and device-specific flags when matching shortcuts, but
            // keep Shift/Option/Control significant so e.g. the shelf's ⇧⌘V hotkey
            // never falls through to the plain ⌘V paste action below.
            let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 123: // left arrow
                viewModel.moveSelection(-1)
                return true
            case 124: // right arrow
                viewModel.moveSelection(1)
                return true
            case 53: // escape
                if viewModel.previewShown {
                    viewModel.previewShown = false
                } else if !viewModel.searchQuery.isEmpty {
                    viewModel.clearSearch()
                } else {
                    controller.hide(restoreFocus: true)
                }
                return true
            case 36: // return
                viewModel.pasteSelection(plain: event.modifierFlags.contains(.option))
                return true
            // Both guard on an empty search field. The shelf keeps that field focused at
            // all times (see the ⌥-digit note above), so an unguarded ⌘V would take the
            // one key a screener needs to paste a search term in, and an unguarded ⌘C
            // would take copying it back out. With text in the field these fall to
            // `default` and the field handles them, exactly as Backspace does below.
            case 8 where shortcutModifiers == .command
                && viewModel.searchQuery.text.isEmpty: // cmd-C — copy the selection
                if viewModel.copySelection() {
                    controller.hide(restoreFocus: true)
                }
                return true
            case 9 where shortcutModifiers == .command
                && viewModel.searchQuery.text.isEmpty: // cmd-V — paste the selection
                viewModel.pasteSelection(plain: false)
                return true
            case 51 where event.modifierFlags.contains(.command): // cmd-delete
                // Clears the search (all pills + text) when one is active; otherwise deletes
                // the selected card.
                if !viewModel.searchQuery.isEmpty {
                    viewModel.clearSearch()
                } else {
                    viewModel.deleteSelection()
                }
                return true
            case 51 where shortcutModifiers.isEmpty: // backspace — delete selected card
                // Search text and pills are handled above/by the field; only an empty
                // search lets Backspace act on the card selection.
                if viewModel.searchQuery.isEmpty {
                    viewModel.deleteSelection()
                    return true
                }
                return false
            case 14 where event.modifierFlags.contains(.command): // cmd-E — edit primary item
                viewModel.beginEdit()
                return true
            case 15 where event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option): // cmd-R — inline-rename primary item
                if let item = viewModel.primaryItem {
                    viewModel.beginInlineRename(item)
                }
                return true
            case 45 where event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option): // cmd-N — new item
                viewModel.beginCreate()
                return true
            case 31 where event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option): // cmd-O — open selected link/file
                viewModel.openSelected()
                return true
            case 6 where event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift): // cmd-Z — undo last delete/removal
                viewModel.undoLast()
                return true
            case 5 where event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && !event.modifierFlags.contains(.option): // cmd-G — show selected item in history
                let onPinboard = { if case .pinboard = viewModel.tab { return true } else { return false } }()
                if (!viewModel.searchQuery.isEmpty || onPinboard), let item = viewModel.primaryItem {
                    viewModel.showInHistory(item)
                }
                return true
            case 49 where viewModel.searchQuery.text.isEmpty: // space previews in browse mode
                viewModel.previewShown.toggle()
                return true
            case 18 where allowsDigitQuickPaste: // 1
                pasteVisible(0)
                return true
            case 19 where allowsDigitQuickPaste: // 2
                pasteVisible(1)
                return true
            case 20 where allowsDigitQuickPaste: // 3
                pasteVisible(2)
                return true
            case 21 where allowsDigitQuickPaste: // 4
                pasteVisible(3)
                return true
            case 23 where allowsDigitQuickPaste: // 5
                pasteVisible(4)
                return true
            case 22 where allowsDigitQuickPaste: // 6
                pasteVisible(5)
                return true
            case 26 where allowsDigitQuickPaste: // 7
                pasteVisible(6)
                return true
            case 28 where allowsDigitQuickPaste: // 8
                pasteVisible(7)
                return true
            case 25 where allowsDigitQuickPaste: // 9
                pasteVisible(8)
                return true
            default:
                return false
            }
        }
        shelfViewModel.onPaste = { [weak self, weak controller] item, plain in
            let paste: () -> Void = { [weak self] in
                guard let self else { return }
                self.pasteFromShelf(item, plainTextOnly: plain)
            }
            if let controller {
                controller.hide(restoreFocus: true, completion: paste)
            } else {
                paste()
            }
        }
        shelfViewModel.onAddToPasteStack = { [weak self] item in
            self?.addToPasteStack(item)
        }
        shelfViewModel.onOpenURL = { [weak controller] url in
            if let controller {
                controller.hide(restoreFocus: true) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        shelfViewModel.onCopyText = { [weak self] text in
            self?.copyText(text)
        }
        shelfViewModel.onCopyItem = { [weak self] item in
            self?.copyToClipboard(item) ?? false
        }
        shelfViewModel.onAdjustColorCopy = { [weak self] hex in
            self?.adjustColorCopy(hex)
        }
        shelfViewModel.onModalPresent = { [weak self] active in
            guard let self else { return }
            if active {
                self.shelfController.presentModal(self.modalHostView)
            } else {
                self.shelfController.dismissModal()
            }
        }
        shelfViewModel.onNewItem = { [weak self] in
            self?.newItem()
        }
        shelfViewModel.onTogglePasteStack = { [weak self] in
            self?.togglePasteStack()
        }
        shelfViewModel.onTogglePrivacyMode = { [weak self] in
            self?.togglePause()
        }
        shelfViewModel.onClearHistory = { [weak self] in
            self?.confirmAndClearHistory()
        }
        shelfViewModel.onExportHistory = { [weak self] in
            self?.exportHistory()
        }
        shelfViewModel.onImportHistory = { [weak self] in
            self?.importHistory()
        }
        shelfViewModel.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        shelfViewModel.onPasteMultiple = { [weak self, weak controller] joined in
            let paste = { [weak self] in
                guard let self else { return }
                self.pasteService.place(
                    [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(joined.utf8))],
                    plainTextOnly: false)
                guard AXIsProcessTrusted() else {
                    HUD.show("Press ⌘V to paste")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [pasteService = self.pasteService] in
                    pasteService.sendPasteKeystroke()
                }
            }
            if let controller {
                controller.hide(restoreFocus: true, completion: paste)
            } else {
                paste()
            }
        }
        controller.onFlagsChanged = { [weak self] event in
            self?.shelfViewModel.commandHeld = event.modifierFlags.contains(.command)
            self?.shelfViewModel.optionHeld = event.modifierFlags.contains(.option)
        }
        controller.onForceClick = { [weak self] in
            // Force-click acts on the card under the cursor: editable kinds (text/rich
            // text/link) open the editor, everything else opens the preview. The click's
            // own mouse-up hasn't resolved yet, so select the card here and set the
            // suppress-paste guard so the release doesn't then paste it.
            guard let self, let uuid = self.shelfViewModel.hoveredItemID,
                  let item = self.shelfViewModel.items.first(where: { $0.uuid == uuid }) else { return }
            self.shelfViewModel.selection.click(uuid)
            self.shelfViewModel.suppressNextCardPaste = true
            switch item.kind {
            case .text, .richText, .link:
                self.shelfViewModel.beginEdit(item)
            case .image, .file, .color:
                self.shelfViewModel.previewShown = true
            }
        }
        return controller
    }()

    private lazy var settingsWindowController = SettingsWindowController(settings: settings, store: store)
    private lazy var onboardingWindowController = OnboardingWindowController()

    init() throws {
        #if DEBUG
        let isDemo = UserDefaults.standard.bool(forKey: Self.demoModeKey)
        #else
        let isDemo = false
        #endif
        self.isDemoMode = isDemo
        let database = try isDemo ? Self.makeDemoDatabase() : DatabaseManager.makeDefault()
        let blobs = BlobStore(directory: database.blobsDirectory)
        let store = ItemStore(writer: database.writer, blobs: blobs)
        self.store = store
        let pinboardStore = PinboardStore(writer: database.writer)
        self.pinboardStore = pinboardStore
        self.pasteService = PasteService(pasteboard: NSPasteboard.general,
                                         keyPoster: CGKeyEventPoster())
        let pasteStackModel = PasteStackModel(store: store)
        self.pasteStackModel = pasteStackModel
        if isDemo {
            DemoData.seed(store: store, pinboards: pinboardStore, pasteStack: pasteStackModel)
        }
        let settings = SettingsStore()
        self.settings = settings
        let linkFetcher = LinkMetadataFetcher(store: store)
        let ocrController = OCRController(store: store)
        let reporter = saveErrors
        self.monitor = ClipboardMonitor(
            pasteboard: NSPasteboard.general,
            rules: RulesEngine(excludedBundleIDs: Set(settings.excludedBundleIDs)),
            frontmostApp: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.bundleIdentifier, app?.localizedName)
            },
            onCapture: { [persistQueue, linkFetcher, ocrController, settings, pasteStackModel] captured in
                persistQueue.async {
                    do {
                        let saved = try store.save(captured)
                        DispatchQueue.main.async {
                            linkFetcher.fetchIfNeeded(for: saved, enabled: settings.fetchLinkPreviews)
                            ocrController.recognizeIfNeeded(for: saved, enabled: settings.recognizeImageText)
                            // While the stack is active, new copies join the queue too —
                            // "copying while the stack is active" enqueues automatically.
                            if pasteStackModel.isActive {
                                pasteStackModel.enqueue(saved)
                            }
                            // Already on the main queue; hop into main-actor isolation for
                            // the one-time activation nudges (see the methods).
                            MainActor.assumeIsolated {
                                CopySoundPlayer.shared.play(settings.copySound)
                                AppCoordinator.showFirstCopyCoachIfNeeded()
                                if !pasteStackModel.isActive {
                                    AppCoordinator.notePasteStackOpportunity()
                                }
                            }
                        }
                    } catch {
                        reporter.report(error)
                    }
                }
            }
        )
        self.linkFetcher = linkFetcher
        self.ocrController = ocrController
        settings.onRulesChange = { [weak self] excludedBundleIDs in
            self?.monitor.rules = RulesEngine(excludedBundleIDs: excludedBundleIDs)
        }
        settings.onHideDuringScreenSharingChange = { [weak self] hide in
            self?.shelfController.setHideDuringScreenSharing(hide)
            self?.pasteStackController.setHideDuringScreenSharing(hide)
        }
        settings.onFavoritesEnabledChange = { [weak self] _ in
            self?.shelfViewModel.favoritesSettingChanged()
        }
        settings.onCompactShelfChange = { [weak self] compact in
            self?.shelfController.setCompactShelf(compact)
        }
        settings.onShelfProDarkChange = { [weak self] proDark in
            self?.shelfController.setProDark(proDark)
            self?.pasteStackController.setProDark(proDark)
        }
        settings.onShowOnboarding = { [weak self] in
            self?.showOnboarding()
        }
        // `self` is fully initialized past this point, so it's safe to capture weakly
        // in `onActiveChange` — the single fan-out point for palette visibility AND
        // engine activation, so the two can never drift out of lockstep (see the
        // `pasteStackModel` doc comment above).
        pasteStackModel.onActiveChange = { [weak self] isActive in
            guard let self else { return }
            self.pasteStackController.syncVisibility(to: isActive)
            self.shelfViewModel.isPasteStackOn = isActive
            if isActive {
                let tapCreated = self.pasteStackEngine.activate()
                NSLog("Copy: Paste Stack tap \(tapCreated ? "activated" : "could not be created, falling back to hotkey")")
                if !tapCreated {
                    KeyboardShortcuts.enable(.pasteNextFromStack)
                    HUD.show("Use Control Option Command N to paste the next item")
                }
            } else {
                self.pasteStackEngine.deactivate()
                KeyboardShortcuts.disable(.pasteNextFromStack)
            }
        }
    }

    func start() {
        // Demo mode never captures the real clipboard (keeps the curated set pristine) and
        // never prunes (its timestamps are backdated for the Time facets).
        guard !isDemoMode else { return }
        monitor.start()
        runRetentionPrune()
        scheduleRetentionTimer()
    }

    /// Isolated, reset-every-launch demo database beside the real `Copy/copy.sqlite`, so
    /// `--demo` never touches real history.
    private static func makeDemoDatabase() throws -> DatabaseManager {
        let demoDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Copy/DemoData", isDirectory: true)
        try? FileManager.default.removeItem(at: demoDir)
        return try DatabaseManager(directory: demoDir)
    }

    /// The one unguided moment in the whole journey: a fresh user has just copied their
    /// very first thing but has no reason to know the shelf exists yet. Nudge them, once,
    /// to summon it, using their actual hotkey. Static (not instance) because the capture
    /// closure that fires it escapes to a background thread and can't hold `self`; gated so
    /// it never fires before onboarding and never repeats.
    private static func showFirstCopyCoachIfNeeded() {
        let defaults = UserDefaults.standard
        let seenKey = "hasSeenFirstCopyCoach"
        guard defaults.bool(forKey: "hasOnboarded"),
              !defaults.bool(forKey: seenKey) else { return }
        defaults.set(true, forKey: seenKey)
        let hotkey = KeyboardShortcuts.getShortcut(for: .toggleShelf)?.description ?? "⇧⌘V"
        HUD.show("Saved to Copy. Press \(hotkey) to open it.", duration: 2.8)
    }

    /// Tracks recent capture times; when an established user copies several things in
    /// quick succession (exactly when a paste stack would help) and hasn't met the
    /// feature yet, introduce it, once. Gated behind the first-copy coach so a brand-new
    /// user copying a fast burst isn't double-nagged.
    private static var recentCaptureTimes: [Date] = []
    private static func notePasteStackOpportunity() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "hasSeenFirstCopyCoach"),
              !defaults.bool(forKey: "hasSeenPasteStackHint") else { return }
        let now = Date()
        recentCaptureTimes.append(now)
        recentCaptureTimes = recentCaptureTimes.filter { now.timeIntervalSince($0) < 10 }
        guard recentCaptureTimes.count >= 3 else { return }
        defaults.set(true, forKey: "hasSeenPasteStackHint")
        let hotkey = KeyboardShortcuts.getShortcut(for: .togglePasteStack)?.description ?? "⇧⌘C"
        HUD.show("Collecting a few things? Press \(hotkey) for the paste stack.", duration: 3.0)
    }

    /// Prunes items past the configured retention window on the persist queue,
    /// always sparing favorites and pinboard members (`ItemStore.prune` invariant).
    private func runRetentionPrune() {
        let cutoff = settings.retention.cutoff
        let store = self.store
        persistQueue.async {
            do {
                let deleted = try store.prune(olderThan: cutoff, maxItems: nil)
                if deleted > 0 {
                    NSLog("Copy: retention pruning removed \(deleted) item(s)")
                }
            } catch {
                NSLog("Copy: retention pruning failed: \(error)")
            }
        }
    }

    private func scheduleRetentionTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.retentionInterval, repeating: Self.retentionInterval)
        timer.setEventHandler { [weak self] in self?.runRetentionPrune() }
        timer.resume()
        retentionTimer = timer
    }

    /// Shows the Settings window (see `SettingsWindowController` for why this is a
    /// window we manage directly instead of going through SwiftUI's `Settings` scene).
    func openSettings() {
        settingsWindowController.show()
    }

    /// Shows the first-run welcome flow. `AppDelegate` calls this once at launch,
    /// gated on the `"hasOnboarded"` UserDefaults flag that `OnboardingView.finish()`
    /// sets on its last step.
    func showOnboarding() {
        onboardingWindowController.show()
    }

    /// Refreshes the shelf's live permission state before showing it (not on hide) —
    /// `shelfViewModel`/`shelfController` are both created once and reused for the
    /// app's lifetime, so without this the permission banner would only ever reflect
    /// whatever was true the very first time the shelf ever appeared.
    func toggleShelf() {
        if !shelfController.isVisible {
            shelfViewModel.refreshPermissionState()
        }
        shelfController.toggle()
    }

    /// Opens the shelf (if not already open) and immediately shows `CreateItemSheet`,
    /// for the status menu's "New Item…" action.
    func newItem() {
        if !shelfController.isVisible {
            shelfViewModel.refreshPermissionState()
            shelfController.show()
        }
        shelfViewModel.beginCreate()
    }

    func togglePause() {
        isPaused.toggle()
        monitor.isPaused = isPaused
        shelfViewModel.isPrivacyModeOn = isPaused
    }

    func recentItems() -> [ClipItem] {
        (try? store.recentItems(limit: 10)) ?? []
    }

    /// Pastes the single most-recent history item directly into the frontmost app,
    /// without opening the shelf — the global "Quick Paste Latest" hotkey. Reuses
    /// `pasteFromShelf`'s place-reps + accessibility ⌘V path (with its "Press ⌘V"
    /// HUD fallback when Accessibility isn't granted).
    func quickPasteLatest() {
        guard let item = (try? store.recentItems(limit: 1))?.first else {
            HUD.show("Nothing to paste")
            return
        }
        pasteFromShelf(item, plainTextOnly: false)
    }

    /// Advances the shelf's active tab to the next pinboard (History → first pinboard
    /// → ... → wraps back to History) — the global "Next Pinboard" hotkey. If the shelf
    /// isn't open yet, this opens it (landing on History) rather than cycling blind;
    /// the user presses the hotkey again to actually advance once the shelf is visible.
    func selectNextPinboard() {
        guard shelfController.isVisible else {
            shelfViewModel.refreshPermissionState()
            shelfController.show()
            return
        }
        let pinboards = shelfViewModel.pinboards
        switch shelfViewModel.tab {
        case .history:
            if let first = pinboards.first, let id = first.id {
                shelfViewModel.tab = .pinboard(id)
            }
        case .pinboard(let currentID):
            let nextIndex = (pinboards.firstIndex(where: { $0.id == currentID }) ?? -1) + 1
            if pinboards.indices.contains(nextIndex), let id = pinboards[nextIndex].id {
                shelfViewModel.tab = .pinboard(id)
            } else {
                shelfViewModel.tab = .history
            }
        }
    }

    /// Enqueues `item` into the Paste Stack (activating the palette if it wasn't
    /// already) from the card context menu's "Add to Paste Stack" action. The palette
    /// re-fits its own size to the new row via `PasteStackView.onContentChange`, so
    /// there's no need to poke the controller directly here.
    func addToPasteStack(_ item: ClipItem) {
        pasteStackModel.enqueue(item)
        HUD.show("Added to Paste Stack")
    }

    /// Places one shelf card on the system clipboard without synthesizing a paste. The
    /// self marker keeps the monitor from ingesting a duplicate; touching the existing
    /// item makes it the current entry in history too. Returns whether the caller should
    /// close the shelf after the copy completed successfully.
    @discardableResult
    func copyToClipboard(_ item: ClipItem) -> Bool {
        guard let id = item.id,
              let reps = try? store.representations(forItemID: id),
              !reps.isEmpty else {
            HUD.show("Item unavailable")
            return false
        }
        pasteService.place(reps, plainTextOnly: false)
        try? store.touch(itemID: id)
        // The monitor ignores our own marked write, so the capture path below never
        // sees this copy and the feedback has to be asked for here.
        CopySoundPlayer.shared.play(settings.copySound)
        return true
    }

    /// Places OCR-recognized text from an image card's "Copy Text" action on the
    /// clipboard (marked self-paste). This is a plain copy, not a paste-in-place — no
    /// keystroke is synthesized, matching `onPasteMultiple`'s "place only" behavior,
    /// since the user asked to copy the text, not paste it.
    func copyText(_ text: String) {
        pasteService.place(
            [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))],
            plainTextOnly: false)
        HUD.show("Text copied")
    }

    /// Places a tweaked color from `ColorAdjustSheet`'s "Copy" button on the clipboard
    /// (marked self-paste). Writes a real `NSKeyedArchiver`-archived `NSColor` under
    /// `colorType` — the shape real color wells (Pages/Keynote/Sketch/`NSColorPanel`)
    /// expect, and what `PasteboardReading.colorHex()` actually decodes via
    /// `readObjects(forClasses: [NSColor.self])` — plus a plain-text hex rep for apps
    /// that only read text. Does not mutate the source item's stored hex.
    func adjustColorCopy(_ hex: String) {
        var reps = [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(hex.utf8))]
        let picked = NSColor(Tokens.color(fromHex: hex))
        let srgb = picked.usingColorSpace(.sRGB) ?? picked
        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: srgb, requiringSecureCoding: true)
            reps.insert(CapturedRepresentation(uti: CopyPasteboard.colorType, data: colorData), at: 0)
        } catch {
            NSLog("Copy: failed to archive adjusted color, placing hex text only: \(error)")
        }
        pasteService.place(reps, plainTextOnly: false)
        HUD.show("Color copied")
    }

    /// Whether the Paste Stack palette/engine are currently active — read by
    /// `AppDelegate` to reflect a checkmark on the "Paste Stack" menu item.
    var isPasteStackActive: Bool { pasteStackModel.isActive }

    /// Flips the Paste Stack on or off. All activation/deactivation — the palette, the
    /// CGEvent tap, and the `.pasteNextFromStack` fallback hotkey — fans out from
    /// `pasteStackModel.isActive`'s `didSet`, wired to `onActiveChange` in `init()`.
    func togglePasteStack() {
        pasteStackModel.isActive.toggle()
    }

    /// Advances the queue and places the next item's representations on the
    /// pasteboard, shared by both the engine-intercepted path and the
    /// `.pasteNextFromStack` fallback hotkey. Returns `false` once the queue is
    /// exhausted, having already deactivated the stack and shown the "finished" HUD.
    @discardableResult
    private func placeNextStackItem() -> Bool {
        guard let reps = pasteStackModel.advanceAndResolve() else {
            deactivatePasteStack()
            HUD.show("Paste Stack finished")
            return false
        }
        pasteService.place(reps, plainTextOnly: false)
        return true
    }

    /// Called by `PasteStackEngine`'s `onIntercept` when the CGEvent tap swallows a
    /// plain ⌘V. This path only runs with Accessibility granted (the tap itself
    /// requires it), so after placing the item it's safe to re-synthesize a marked ⌘V
    /// and have the frontmost app receive it automatically.
    private func pasteNextViaEngine() {
        guard placeNextStackItem() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PasteStackEngine.postMarkedPasteKeystroke()
        }
    }

    /// `.pasteNextFromStack` fallback hotkey handler — only reachable while the tap
    /// couldn't be created (no Accessibility; see `pasteStackModel.onActiveChange`).
    /// Without Accessibility we can't reliably synthesize a ⌘V ourselves (same reason
    /// `pasteFromShelf`/`onPasteMultiple` gate `sendPasteKeystroke()` behind
    /// `AXIsProcessTrusted()`), so this places the item and lets the user's own ⌘V —
    /// which the OS delivers directly, no synthesis needed — do the actual pasting.
    func pasteNextFromStack() {
        guard placeNextStackItem() else { return }
        HUD.show("Ready to paste. Press Command V.")
    }

    private func deactivatePasteStack() {
        pasteStackModel.isActive = false
    }

    /// Called from `AppDelegate.applicationWillTerminate` so the event tap never
    /// outlives the app process. `pasteStackEngine.deactivate()` is called directly
    /// too, as a defensive no-op, in case the tap was ever active without
    /// `pasteStackModel.isActive` reflecting it.
    func applicationWillTerminate() {
        deactivatePasteStack()
        pasteStackEngine.deactivate()
    }

    func clearHistory() {
        do {
            try store.clearHistory(keepFavorites: true)
        } catch {
            NSLog("Copy: failed to clear history: \(error)")
        }
    }

    /// Confirms before clearing, shared by the status menu's "Clear History…" item
    /// (`AppDelegate.clearHistory`) and the in-drawer menu's equivalent action
    /// (`ShelfViewModel.onClearHistory`) so both paths use the exact same confirmation
    /// copy and semantics — one implementation instead of two. The alert's window level
    /// is bumped to `.statusBar`, matching `ShelfRootView`'s pinboard-delete confirm, so
    /// it renders above the always-on-top shelf panel when triggered from there.
    func confirmAndClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Favorites are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            clearHistory()
        }
    }

    /// "Export…" status-menu action — writes the full history and pinboards to a
    /// user-chosen `.json` file via `ArchiveController`.
    func exportHistory() {
        archiveController.exportHistory()
    }

    /// "Import…" status-menu action — restores history and pinboards from a
    /// user-chosen `.json` backup file via `ArchiveController`, deduping by content
    /// hash so re-importing the same file never creates duplicates.
    func importHistory() {
        archiveController.importHistory()
    }

    /// Puts the item on the clipboard and pastes it into the frontmost app.
    /// Without Accessibility, the item stays on the clipboard for a manual ⌘V.
    func paste(_ item: ClipItem) {
        pasteFromShelf(item, plainTextOnly: false)
    }

    func pasteFromShelf(_ item: ClipItem, plainTextOnly: Bool) {
        guard let id = item.id,
              let reps = try? store.representations(forItemID: id),
              !reps.isEmpty else {
            HUD.show("Item unavailable")
            return
        }
        pasteService.place(reps, plainTextOnly: plainTextOnly)
        try? store.touch(itemID: id)

        guard AXIsProcessTrusted() else {
            HUD.show("Press ⌘V to paste")
            promptForAccessibility()
            return
        }
        // Give app activation time to settle so the keystroke lands in the frontmost app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [pasteService] in
            pasteService.sendPasteKeystroke()
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
