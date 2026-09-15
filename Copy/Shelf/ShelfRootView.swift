import SwiftUI
import CopyCore
import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

struct ShelfRootView: View {
    @Bindable var viewModel: ShelfViewModel
    @State private var permissionBannerDismissed = false
    /// Pinboard tab frames (id → frame in the "shelfRoot" space), published by each tab and
    /// consumed by the shelf-level `PinboardDropDelegate` to route a drop to the right tab.
    @State private var pinboardTabFrames: [Int64: CGRect] = [:]
    /// Persisted so the keyboard legend, once dismissed, stays gone. Read once here;
    /// `dismissLegend()` writes it back. Defaults to shown (false) for new users.
    @State private var legendDismissed = UserDefaults.standard.bool(forKey: Self.legendDismissedKey)

    private static let legendDismissedKey = "shelfKeyboardLegendDismissed"

    /// The legend teaches the keyboard path, so it earns its slim strip when there are
    /// cards to act on and the shelf is at full height (compact mode trades this away for
    /// density). Holding ⌘ re-summons it even after it's been dismissed.
    private var showsLegend: Bool {
        guard !viewModel.items.isEmpty, !viewModel.settings.compactShelf else { return false }
        return !legendDismissed || viewModel.commandHeld
    }

    private func dismissLegend() {
        UserDefaults.standard.set(true, forKey: Self.legendDismissedKey)
        withAnimation(.easeOut(duration: 0.15)) { legendDismissed = true }
    }

    /// Reads `viewModel.accessibilityTrusted` rather than checking `AXIsProcessTrusted()`
    /// itself, since the shelf panel + this view are created once and reused for the
    /// app's lifetime — a one-time `.onAppear` read here would only ever reflect
    /// whatever was true the very first time the shelf ever appeared. `AppCoordinator`
    /// refreshes that state on every shelf open (see `ShelfViewModel.refreshPermissionState()`),
    /// so once access is granted, the next open simply stops showing the banner.
    private var showsPermissionBanner: Bool {
        !viewModel.accessibilityTrusted && !permissionBannerDismissed
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPermissionBanner {
                PermissionBanner(onDismiss: { permissionBannerDismissed = true })
            }
            ShelfHeader(viewModel: viewModel)
                // Above the cards so the search suggestions dropdown floats over them.
                .zIndex(1)
            Divider()
            ShelfItemsRow(viewModel: viewModel)
            if showsLegend {
                KeyboardLegend(onDismiss: dismissLegend)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(corners: .top(12))
        // Card → pinboard filing is handled here, at the shelf root, because a per-tab
        // `.onDrop` never establishes a working drop region on the small pills inside this
        // borderless non-activating glass panel (a shelf-level drop, by contrast, fires
        // reliably). The delegate maps the drop location to the tab under it using each
        // tab's frame, collected via PinboardTabFramesKey below.
        .coordinateSpace(name: "shelfRoot")
        .onPreferenceChange(PinboardTabFramesKey.self) { pinboardTabFrames = $0 }
        .onDrop(of: [UTType.copyItem], delegate: PinboardDropDelegate(
            tabFrames: { pinboardTabFrames },
            onTargetChange: { viewModel.dropTargetedPinboardID = $0 },
            onFile: { id, uuids in
                guard let pinboard = viewModel.pinboards.first(where: { $0.id == id }) else { return }
                viewModel.dropItems(uuids: uuids, toPinboard: pinboard)
                // Open the pinboard we just filed into, so the drop's result shows at once.
                viewModel.tab = .pinboard(id)
            }
        ))
        // Pro-dark: force the marketing electric-blue accent regardless of the system
        // accent color. The forced dark appearance itself is set on the panel window in
        // `ShelfPanelController`, which cascades to this hosted content.
        .tint(viewModel.settings.shelfProDark ? Tokens.electricBlue : nil)
        // Edit/Create/Adjust Color/Tips are shown as a centered child window over the
        // shelf (see `ShelfModalHostView`), not as attached sheets that overflow off the
        // bottom of the screen. This view is always on screen while the shelf is open, so
        // it reliably drives the host window's show/hide as the modal state changes.
        .onChange(of: hasActiveModal) { _, active in viewModel.onModalPresent?(active) }
    }

    private var hasActiveModal: Bool {
        viewModel.editingItem != nil || viewModel.creatingItem
            || viewModel.adjustingColorItem != nil || viewModel.showingTips
    }
}

/// Slim, quiet strip (no colored fill — just an SF Symbol and text on the shelf's
/// existing material) shown while Accessibility isn't granted, since without it
/// `AppCoordinator.pasteFromShelf` can only place the item on the clipboard rather
/// than actually paste it into the frontmost app.
private struct PermissionBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Copy needs Accessibility access to paste.")
                    .font(Tokens.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { openAccessibilitySettings() }
                    .buttonStyle(.link)
                    .font(Tokens.caption)
                Spacer(minLength: 8)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(Tokens.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Tokens.shelfPadding)
            .padding(.vertical, 6)
            Divider()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ShelfHeader: View {
    @Bindable var viewModel: ShelfViewModel
    @FocusState private var searchFocused: Bool

    /// Quiet scope hint: on a pinboard tab, the search field's placeholder names the
    /// board so the user knows a query only searches its members, not all of history.
    /// Falls back to the global "Search" placeholder on History, and if the tab's
    /// pinboard can't be resolved (e.g. mid-delete).
    private var searchPlaceholder: String {
        if case .pinboard(let id) = viewModel.tab,
           let name = viewModel.pinboards.first(where: { $0.id == id })?.name {
            return "Search \(name)"
        }
        return "Search or filter…"
    }

    var body: some View {
        HStack(spacing: 10) {
            ShelfTabs(viewModel: viewModel)
            Spacer(minLength: 12)
            SearchTokenField(viewModel: viewModel, placeholder: searchPlaceholder, focused: $searchFocused)
                .frame(maxWidth: 360)
            PasteStackButton(viewModel: viewModel)
            DrawerMenu(viewModel: viewModel)
        }
        .padding(.horizontal, Tokens.shelfPadding)
        .padding(.vertical, 8)
        // Not auto-focused on open — the shelf opens in browse mode. Keep the view model in
        // sync with the field's focus, and honor a focus request from the key handler
        // (type-to-search).
        .onChange(of: searchFocused) { _, focused in viewModel.isSearchFieldFocused = focused }
        .onChange(of: viewModel.focusSearchRequested) { _, requested in
            if requested {
                searchFocused = true
                viewModel.focusSearchRequested = false
                // Focusing select-alls the field, so the letter that started the search
                // would be replaced by the next keystroke. Move the caret to the end once
                // focus lands (type-to-search only — a manual click keeps its position).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                    }
                }
            }
        }
    }
}

/// Header control that opens the Paste Stack palette (`onTogglePasteStack`), tinting to the
/// accent while the stack is active. While ⌘ is held it reveals the stack's rebindable
/// hotkey as a `KeyCap`, matching the shelf's other ⌘-hold hints (the card number badges).
private struct PasteStackButton: View {
    @Bindable var viewModel: ShelfViewModel

    private var hotkey: String {
        KeyboardShortcuts.getShortcut(for: .togglePasteStack)?.description ?? "⇧⌘C"
    }

    var body: some View {
        HStack(spacing: 5) {
            IconButton(systemName: "square.stack.3d.up", fontSize: 15,
                       size: CGSize(width: 34, height: 30),
                       tint: viewModel.isPasteStackOn ? Color.accentColor : .secondary,
                       help: "Paste Stack (\(hotkey))") {
                viewModel.onTogglePasteStack?()
            }
            if viewModel.commandHeld {
                KeyCap(text: hotkey)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: viewModel.commandHeld)
    }
}

/// The shelf's own "more" control — a discreet ellipsis button mirroring every
/// status-menu action, so the app is fully usable with the menu bar icon hidden
/// (`SettingsStore.hideMenuBarIcon`). Deliberately quiet (borderless, no chevron,
/// secondary tint) rather than a toolbar, to match the shelf's existing icon-button
/// language (e.g. the "Add Pinboard" `+` in `ShelfTabs`).
private struct DrawerMenu: View {
    let viewModel: ShelfViewModel
    @State private var target = MenuActionTarget()

    var body: some View {
        // A plain Button that pops an NSMenu, rather than a SwiftUI `Menu`: the latter's
        // `.borderlessButton` style only made the glyph pixels clickable, so the ⋯ was
        // extremely hard to hit. `IconButton` gives a large, hover-highlighted,
        // fully-hittable target with a tooltip.
        IconButton(systemName: "ellipsis.circle", fontSize: 16,
                   size: CGSize(width: 34, height: 30), help: "More", action: showMenu)
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = MenuAction(run: action)
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("New Item…") { viewModel.onNewItem?() }
        add("Paste Stack", checked: viewModel.isPasteStackOn) { viewModel.onTogglePasteStack?() }
        add(viewModel.isPrivacyModeOn ? "Resume Monitoring" : "Pause Monitoring") { viewModel.onTogglePrivacyMode?() }
        menu.addItem(.separator())
        add("Clear History…") { viewModel.onClearHistory?() }
        add("Export…") { viewModel.onExportHistory?() }
        add("Import…") { viewModel.onImportHistory?() }
        menu.addItem(.separator())
        add("Keyboard & Tips…") { viewModel.showingTips = true }
        add("Settings…") { viewModel.onOpenSettings?() }
        add("Check for Updates…") { viewModel.onCheckForUpdates?() }
        menu.addItem(.separator())
        add("Quit Copy") { viewModel.onQuit?() }

        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = content.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: content)
    }
}

/// Wraps a Swift closure so it can ride an `NSMenuItem`'s `representedObject` and be
/// invoked by `MenuActionTarget` — AppKit menu items are selector-based, not closure-based.
private final class MenuAction {
    let run: () -> Void
    init(run: @escaping () -> Void) { self.run = run }
}

private final class MenuActionTarget: NSObject {
    @objc func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }
}

/// Left-hand pill row: History, then pinboards, then Add Pinboard.
private struct ShelfTabs: View {
    @Bindable var viewModel: ShelfViewModel
    @State private var createPresented = false
    @State private var renamingPinboard: Pinboard?

    var body: some View {
        HStack(spacing: 4) {
            TabPill(
                label: "History",
                symbol: "clock",
                isSelected: viewModel.tab == .history,
                shortcutHint: viewModel.commandHeld ? "1" : nil,
                action: { viewModel.tab = .history }
            )
            ForEach(Array(viewModel.pinboards.enumerated()), id: \.element.id) { offset, pinboard in
                TabPill(
                    label: pinboard.name,
                    symbol: pinboard.symbol,
                    emoji: pinboard.emoji,
                    tint: pinboard.tint,
                    showsSymbol: false,
                    isSelected: pinboard.id.map { viewModel.tab == .pinboard($0) } ?? false,
                    isDropTargeted: pinboard.id != nil && viewModel.dropTargetedPinboardID == pinboard.id,
                    // ⌘1 is History, so pinboards start at ⌘2; only the first eight get a
                    // hint (⌘9 is the ceiling of the number-key routing).
                    shortcutHint: (viewModel.commandHeld && offset + 2 <= 9) ? "\(offset + 2)" : nil,
                    action: {
                        guard let id = pinboard.id else { return }
                        // Clicking the already-selected pinboard opens its editor; otherwise
                        // it just switches to it.
                        if viewModel.tab == .pinboard(id) {
                            renamingPinboard = pinboard
                        } else {
                            viewModel.tab = .pinboard(id)
                        }
                    }
                )
                .contextMenu {
                    // "Edit…" opens PinboardEditPopover, which edits name, symbol, emoji,
                    // and color (including a custom color picker) in one place.
                    Button("Edit…") { renamingPinboard = pinboard }
                    Button("Delete Pinboard", role: .destructive) { confirmDelete(pinboard) }
                }
                .popover(isPresented: Binding(
                    get: { pinboard.id != nil && renamingPinboard?.id == pinboard.id },
                    set: { if !$0 { renamingPinboard = nil } }
                )) {
                    PinboardEditPopover(mode: .rename(pinboard)) { name, symbol, emoji, tint in
                        if let id = pinboard.id {
                            viewModel.renamePinboard(id: id, to: name)
                            viewModel.setPinboardSymbol(id: id, symbol)
                            viewModel.setPinboardEmoji(id: id, emoji)
                            viewModel.setPinboardTint(id: id, tint)
                        }
                        renamingPinboard = nil
                    }
                }
                // Publish this tab's frame (in the shelf's "shelfRoot" space) so the
                // shelf-level PinboardDropDelegate can map a drop location back to this
                // pinboard. Drops are handled at the shelf root, not per-tab — see
                // PinboardDropDelegate for why.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PinboardTabFramesKey.self,
                            value: pinboard.id.map { [$0: geo.frame(in: .named("shelfRoot"))] } ?? [:]
                        )
                    }
                )
            }
            IconButton(systemName: "plus", fontSize: 12,
                       size: CGSize(width: 34, height: 30), help: "New pinboard") {
                createPresented = true
            }
            .popover(isPresented: $createPresented) {
                PinboardEditPopover(mode: .create) { name, symbol, emoji, tint in
                    viewModel.createPinboard(name: name, symbol: symbol, emoji: emoji, tint: tint)
                }
            }
        }
        // A near-invisible but real backing across the whole tab strip so a card dropped
        // onto a pinboard tab routes to THIS panel instead of passing through the glass
        // surface to the window behind (which pasted the card's text into the app
        // underneath). The window server treats a pixel as pass-through only when its
        // composited alpha rounds to zero, so this needs alpha above 1/255 (0.001 rounds
        // to 0 and still passed drags through); 0.02 is ~2% and imperceptible over glass.
        .background(Color.black.opacity(0.02))
        .onChange(of: createPresented) { _, isPresented in
            viewModel.pinboardPopoverShown = isPresented || renamingPinboard != nil
        }
        .onChange(of: renamingPinboard) { _, newValue in
            viewModel.pinboardPopoverShown = createPresented || newValue != nil
        }
    }

    /// Matches the existing `NSAlert` confirm pattern (`AppDelegate.clearHistory`), with
    /// the alert's window bumped to the shelf panel's own `.statusBar` level — otherwise
    /// the alert would render behind the always-on-top, non-activating shelf panel.
    private func confirmDelete(_ pinboard: Pinboard) {
        guard let id = pinboard.id else { return }
        let alert = NSAlert()
        alert.messageText = "Delete pinboard \(pinboard.name)?"
        alert.informativeText = "Items stay in your history."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.deletePinboard(id: id)
        }
    }
}

private struct TabPill: View {
    let label: String
    let symbol: String
    /// A user-chosen emoji shown in place of the SF Symbol, when set. `nil`/untinted
    /// pinboards (and the History tab) render exactly as before this feature.
    var emoji: String? = nil
    /// A user-chosen hex color (e.g. "FF3B30"); empty means no color identity.
    var tint: String = ""
    /// Whether to draw the SF Symbol when no emoji is set. History uses it (a clock);
    /// pinboards don't — their identity is the color dot and optional emoji.
    var showsSymbol: Bool = true
    let isSelected: Bool
    var isDropTargeted: Bool = false
    /// The ⌘-number that jumps to this tab (e.g. "1"), shown as a badge while ⌘ is held.
    var shortcutHint: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    private var tintColor: Color? {
        tint.isEmpty ? nil : Tokens.color(fromHex: tint)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let emoji, !emoji.isEmpty {
                Text(emoji)
            } else if showsSymbol {
                Image(systemName: symbol)
            }
            Text(label)
            if let tintColor {
                Circle()
                    .fill(tintColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            if let shortcutHint {
                Text("⌘\(shortcutHint)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6)))
                    .accessibilityHidden(true)
            }
        }
        .font(Tokens.caption)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        // A drop-targeted tab visibly pops so it's unmistakable which pinboard a dragged
        // card will land in, even when the cursor's drag chip sits near it.
        .scaleEffect(isDropTargeted ? 1.08 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDropTargeted)
        // A plain tappable surface, NOT a Button, so the `.onDrop` each tab carries in
        // `ShelfTabs` is a reliable drop target. A SwiftUI `Button` on macOS fights the
        // drag session for the mouse-up, so dragging a card onto a pinboard landed only
        // intermittently; a tap gesture on a plain view coexists with `.onDrop` cleanly.
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .onHover { isHovering = $0 }
    }

    private var backgroundFill: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.24) }
        if isSelected {
            if let tintColor { return tintColor.opacity(0.18) }
            return Color.primary.opacity(0.08)
        }
        return isHovering ? Color.primary.opacity(0.05) : .clear
    }
}

private struct ShelfItemsRow: View {
    @Bindable var viewModel: ShelfViewModel

    private var currentPinboardID: Int64? {
        if case .pinboard(let id) = viewModel.tab { return id }
        return nil
    }

    /// Read straight from `SettingsStore` (both it and `ShelfViewModel` are
    /// `@Observable`), so toggling "Shelf Size" in Settings re-renders this row
    /// immediately — no separate change-hook plumbing needed on the SwiftUI side.
    private var compact: Bool { viewModel.settings.compactShelf }

    var body: some View {
        if viewModel.items.isEmpty {
            ShelfEmptyState(viewModel: viewModel)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Tokens.cardGap(compact: compact)) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.uuid) { index, item in
                            // A divider between the leading favorites and the rest.
                            if index == viewModel.favoritesCount,
                               viewModel.favoritesCount > 0,
                               viewModel.favoritesCount < viewModel.items.count {
                                FavoritesDivider(compact: compact)
                            }
                            ItemCardView(
                                item: item,
                                isSelected: viewModel.isSelected(item),
                                isInlineRenaming: viewModel.inlineRenamingItemID == item.id,
                                store: viewModel.store,
                                pinboards: viewModel.pinboards,
                                currentPinboardID: currentPinboardID,
                                favoritesEnabled: viewModel.settings.favoritesEnabled,
                                compact: compact,
                                searchQuery: viewModel.searchQuery.text,
                                isFlashing: viewModel.flashItemID == item.uuid,
                                pasteNumber: (viewModel.optionHeld && index < 9) ? index + 1 : nil,
                                canShowInHistory: !viewModel.searchQuery.isEmpty || currentPinboardID != nil,
                                onClick: { modifiers in viewModel.handleCardClick(item, modifiers: modifiers) },
                                onHoverChanged: { hovering in
                                    if hovering {
                                        viewModel.hoveredItemID = item.uuid
                                    } else if viewModel.hoveredItemID == item.uuid {
                                        viewModel.hoveredItemID = nil
                                    }
                                },
                                onPaste: { viewModel.requestPaste(item, plain: false) },
                                onPastePlain: { viewModel.requestPaste(item, plain: true) },
                                onEdit: { viewModel.beginEdit(item) },
                                onAdjustColor: { viewModel.beginAdjustColor(item) },
                                onBeginInlineRename: { viewModel.beginInlineRename(item) },
                                onCommitInlineRename: { viewModel.commitInlineRename(item, to: $0) },
                                onCancelInlineRename: { viewModel.cancelInlineRename() },
                                onToggleFavorite: { viewModel.toggleFavorite(item) },
                                onAddToPinboard: { id in viewModel.addItem(item, toPinboard: id) },
                                onRemoveFromPinboard: {
                                    if let currentPinboardID {
                                        viewModel.removeItem(item, fromPinboard: currentPinboardID)
                                    }
                                },
                                onAddToPasteStack: { viewModel.addToPasteStack(item) },
                                onCopyText: { viewModel.copyText(item) },
                                onQuickLook: { viewModel.quickLook(item) },
                                onOpen: { viewModel.open(item) },
                                onShowInHistory: { viewModel.showInHistory(item) },
                                onRotate: { viewModel.rotateImage(item, clockwise: $0) },
                                onDelete: { viewModel.delete(item) },
                                dragProvider: { viewModel.dragProvider(for: item) },
                                dragBadgeCount: viewModel.isSelected(item) ? viewModel.selection.selected.count : 1
                            )
                            .id(item.uuid)
                            // The LazyHStack only builds a card once it scrolls into view,
                            // so this fires as the user nears the oldest card and widens the
                            // fetch window. Without it the shelf stopped at the first page.
                            .onAppear { viewModel.loadMoreIfNeeded(at: index) }
                            .popover(isPresented: Binding(
                                get: { viewModel.isSelected(item) && item.uuid == viewModel.selection.primary && viewModel.previewShown },
                                set: { viewModel.previewShown = $0 }
                            )) {
                                PreviewPane(item: item, store: viewModel.store)
                            }
                        }
                    }
                    .padding(.horizontal, Tokens.shelfPadding(compact: compact))
                    .padding(.vertical, compact ? 10 : 16)
                    // Give the whole row (including the gaps between cards) a real backing
                    // view so a scroll wheel over a gap routes to the scroll view instead
                    // of passing through to the panel behind. A near-zero-opacity fill is
                    // enough to create the hit-testable NSView; `contentShape` alone (which
                    // affects gesture hit-testing, not AppKit scroll-wheel routing) wasn't.
                    .background(Color.black.opacity(0.001))
                }
                .onChange(of: viewModel.selection.primary) { _, newPrimary in
                    if let newPrimary {
                        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            proxy.scrollTo(newPrimary, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(newPrimary, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The vertical rule between the leading favorited cards and the rest of the shelf,
/// topped with a small star so the grouping reads at a glance.
private struct FavoritesDivider: View {
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.8))
                .frame(width: 1.5)
        }
        .frame(height: Tokens.cardHeight(compact: compact))
        .padding(.horizontal, 2)
        .accessibilityLabel("Favorites divider")
    }
}

/// Empty state for the items row, tailored to the active tab and search state.
private struct ShelfEmptyState: View {
    let viewModel: ShelfViewModel

    private var symbolName: String {
        switch viewModel.tab {
        case .history:
            return "square.on.square"
        case .pinboard(let id):
            return viewModel.pinboards.first(where: { $0.id == id })?.symbol ?? "pin"
        }
    }

    private var headline: String {
        if !viewModel.searchQuery.isEmpty {
            let text = viewModel.searchQuery.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "No matches for these filters" : "No matches for \"\(text)\""
        }
        switch viewModel.tab {
        case .history: return "Copy something to get started"
        case .pinboard: return "Nothing pinned yet"
        }
    }

    private var caption: String? {
        guard viewModel.searchQuery.isEmpty, case .pinboard = viewModel.tab else { return nil }
        return "Drag a card here or use Add to Pinboard"
    }

    /// True only on the empty History tab with no active search: the genuine "nothing
    /// captured yet" moment, where a short first-run primer earns its space. Search and
    /// pinboard empties stay minimal.
    private var isFirstRun: Bool {
        guard viewModel.searchQuery.isEmpty else { return false }
        if case .history = viewModel.tab { return true }
        return false
    }

    var body: some View {
        VStack(spacing: isFirstRun ? 10 : 6) {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if isFirstRun {
                Text("Text, images, links, files, and colors all land here automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    KeyHint(key: "⇧⌘V", label: "Open Copy")
                    KeyHint(key: "↩", label: "Paste")
                    KeyHint(key: "Space", label: "Preview")
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A slim, dismissible strip along the shelf's bottom that teaches the core keyboard
/// path. Sized to fit the standard shelf's spare vertical space below the cards; hidden
/// in compact mode and once dismissed (see `ShelfRootView.showsLegend`).
private struct KeyboardLegend: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↩", label: "Paste")
            KeyHint(key: "Space", label: "Preview")
            KeyHint(key: "⌥↩", label: "Plain text")
            KeyHint(key: "⌘⌫", label: "Delete")
            Spacer(minLength: 8)
            IconButton(systemName: "xmark", fontSize: 9,
                       size: CGSize(width: 22, height: 20), help: "Hide keyboard tips",
                       action: onDismiss)
        }
        .padding(.horizontal, Tokens.shelfPadding)
        .padding(.top, 4)
        .padding(.bottom, 11)
    }
}
