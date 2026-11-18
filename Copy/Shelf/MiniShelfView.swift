import AppKit
import CopyCore
import KeyboardShortcuts
import SwiftUI

/// The mini shelf: a small panel that opens above the text cursor (see
/// `ShelfPanelController.show(mode:)`), with the history as a vertical list. It runs on the
/// same `ShelfViewModel` as the full shelf, so search, pinboards, selection, paste, drag and
/// drop, and the paste stack all behave the same; only the layout differs.
struct MiniShelfView: View {
    @Bindable var viewModel: ShelfViewModel
    @FocusState private var searchFocused: Bool
    @State private var permissionBannerDismissed = false

    static let cornerRadius: CGFloat = 14
    /// Room the lists leave at their bottom for the floating buttons.
    static let controlsClearance: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.accessibilityTrusted && !permissionBannerDismissed {
                PermissionBanner(onDismiss: { permissionBannerDismissed = true })
            }
            HStack(spacing: 0) {
                if viewModel.miniShowsPinboards {
                    MiniPinboardRail(viewModel: viewModel)
                    Divider()
                }
                VStack(spacing: 0) {
                    if viewModel.miniSearchShown {
                        SearchTokenField(viewModel: viewModel, placeholder: searchPlaceholder,
                                         focused: $searchFocused, fitsDropdownToField: true)
                            .padding([.horizontal, .top], 8)
                            // Above the list so the suggestions float over it.
                            .zIndex(1)
                    }
                    MiniItemsList(viewModel: viewModel)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            MiniShelfControls(viewModel: viewModel)
                .padding(8)
        }
        .modifier(SearchFocusSync(viewModel: viewModel, focused: $searchFocused))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(cornerRadius: Self.cornerRadius)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// On a pinboard, names the board so the user knows the search is scoped to it.
    private var searchPlaceholder: String {
        if case .pinboard(let id) = viewModel.tab,
           let name = viewModel.pinboards.first(where: { $0.id == id })?.name {
            return "Search \(name)"
        }
        return "Search or filter…"
    }
}

/// The search, paste stack and pinboard-column buttons, floating over the shelf's
/// bottom-left corner rather than taking a column of their own.
private struct MiniShelfControls: View {
    @Bindable var viewModel: ShelfViewModel

    private var stackHotkey: String {
        KeyboardShortcuts.getShortcut(for: .togglePasteStack)?.description ?? "⇧⌘C"
    }

    var body: some View {
        HStack(spacing: 1) {
            button("magnifyingglass", on: viewModel.miniSearchShown,
                   help: viewModel.miniSearchShown ? "Close Search" : "Search") {
                viewModel.toggleMiniSearch()
            }
            button("square.stack.3d.up", on: viewModel.isPasteStackOn, help: "Paste Stack (\(stackHotkey))") {
                viewModel.onTogglePasteStack?()
            }
            button("sidebar.left", on: viewModel.miniShowsPinboards,
                   help: viewModel.miniShowsPinboards ? "Hide Pinboards" : "Show Pinboards") {
                viewModel.miniShowsPinboards.toggle()
            }
        }
        .padding(2)
        // Blurs the cards under it, not what is behind the window (see `DropdownBackdrop`).
        .background(DropdownBackdrop(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private func button(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        IconButton(systemName: symbol, fontSize: 11, size: CGSize(width: 24, height: 22),
                   tint: on ? Color.accentColor : .secondary, help: help, action: action)
    }
}

/// The pinboard column: History, then each pinboard as a small circle. Cards dropped on a
/// circle are filed into that board; like the full shelf's tabs, each circle publishes its
/// frame so `ShelfHostingView` can resolve the drop.
private struct MiniPinboardRail: View {
    @Bindable var viewModel: ShelfViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                MiniRailCircle(label: "History", symbol: "clock", isSelected: viewModel.tab == .history) {
                    viewModel.selectTab(.history)
                }
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 18, height: 1)
                ForEach(viewModel.pinboards, id: \.id) { pinboard in
                    MiniRailCircle(
                        label: pinboard.name,
                        symbol: pinboard.symbol,
                        emoji: pinboard.emoji,
                        tint: pinboard.tint,
                        isSelected: pinboard.id.map { viewModel.tab == .pinboard($0) } ?? false,
                        isDropTargeted: pinboard.id != nil && viewModel.dropTargetedPinboardID == pinboard.id
                    ) {
                        if let id = pinboard.id { viewModel.selectTab(.pinboard(id)) }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: PinboardTabFramesKey.self,
                                value: pinboard.id.map { [$0: geo.frame(in: .named("shelfRoot"))] } ?? [:]
                            )
                        }
                    )
                }
            }
            .padding(.top, 10)
            .padding(.bottom, MiniShelfView.controlsClearance)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 44)
        // A real backing so a card dropped on a circle routes to this panel instead of
        // passing through the glass to the window behind (see `ShelfTabs`).
        .background(Color.primary.opacity(0.03))
    }
}

private struct MiniRailCircle: View {
    let label: String
    let symbol: String
    var emoji: String? = nil
    var tint: String = ""
    let isSelected: Bool
    var isDropTargeted: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    private var tintColor: Color? { tint.isEmpty ? nil : Tokens.color(fromHex: tint) }
    private var ringColor: Color { isDropTargeted ? (tintColor ?? .accentColor) : .accentColor }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 13))
            } else if let tintColor {
                Circle().fill(tintColor).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))
            }
        }
        .frame(width: 28, height: 28)
        .overlay(Circle().strokeBorder(ringColor, lineWidth: isDropTargeted ? 2 : 1.5)
            .opacity(isSelected || isDropTargeted ? 1 : 0))
        .scaleEffect(isDropTargeted ? 1.12 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDropTargeted)
        // A tap gesture, not a Button, so a card dragged onto it isn't fought for the
        // mouse-up (see `TabPill`).
        .contentShape(Circle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isDropTargeted { return (tintColor ?? .accentColor).opacity(0.24) }
        if let tintColor, isSelected { return tintColor.opacity(0.22) }
        if isSelected { return Color.primary.opacity(0.1) }
        return isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)
    }
}

/// The history as a vertical list of compact rows.
private struct MiniItemsList: View {
    @Bindable var viewModel: ShelfViewModel

    private var currentPinboardID: Int64? {
        if case .pinboard(let id) = viewModel.tab { return id }
        return nil
    }

    var body: some View {
        if viewModel.items.isEmpty {
            ShelfEmptyState(viewModel: viewModel)
                .padding(.bottom, MiniShelfView.controlsClearance)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.uuid) { index, item in
                            if index == viewModel.favoritesCount,
                               viewModel.favoritesCount > 0,
                               viewModel.favoritesCount < viewModel.items.count {
                                MiniFavoritesDivider()
                            }
                            row(item, index: index)
                                .id(item.uuid)
                                // Widens the fetch window as the list nears its oldest row.
                                .onAppear {
                                    viewModel.loadMoreIfNeeded(at: index)
                                    viewModel.fetchLinkPreviewIfNeeded(for: item)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, MiniShelfView.controlsClearance)
                    // A real backing so the scroll wheel over a gap reaches the list.
                    .background(Color.black.opacity(0.001))
                }
                .onChange(of: viewModel.selection.primary) { _, newPrimary in
                    guard let newPrimary else { return }
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        proxy.scrollTo(newPrimary)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(newPrimary) }
                    }
                }
            }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        MiniItemRow(
            item: item,
            isSelected: viewModel.isSelected(item),
            isInlineRenaming: viewModel.inlineRenamingItemID == item.id,
            store: viewModel.store,
            pinboards: viewModel.pinboards,
            currentPinboardID: currentPinboardID,
            favoritesEnabled: viewModel.settings.favoritesEnabled,
            previewLines: viewModel.settings.miniShelfSize.previewLines,
            isFlashing: viewModel.flashItemID == item.uuid,
            hideSecrets: viewModel.settings.hideSecrets,
            secretsRevealed: viewModel.revealedSecretIDs.contains(item.uuid),
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
            onToggleSecrets: { viewModel.toggleSecretsRevealed(item) },
            onAddToPinboard: { id in viewModel.addItem(item, toPinboard: id) },
            onRemoveFromPinboard: {
                if let currentPinboardID { viewModel.removeItem(item, fromPinboard: currentPinboardID) }
            },
            onAddToPasteStack: { viewModel.addToPasteStack(item) },
            onSplitToPasteStack: { viewModel.splittingItem = item },
            onCopyText: { viewModel.copyText(item) },
            onQuickLook: { viewModel.quickLook(item) },
            onOpen: { viewModel.open(item) },
            onShowInHistory: { viewModel.showInHistory(item) },
            onRotate: { viewModel.rotateImage(item, clockwise: $0) },
            onDelete: { viewModel.delete(item) },
            dragProvider: { viewModel.dragProvider(for: item) },
            dragBadgeCount: viewModel.isSelected(item) ? viewModel.selection.selected.count : 1
        )
        // Space previews the selected row, as it does a card in the full shelf.
        .popover(isPresented: Binding(
            get: { viewModel.isSelected(item) && item.uuid == viewModel.selection.primary && viewModel.previewShown },
            set: { viewModel.previewShown = $0 }
        ), arrowEdge: .trailing) {
            PreviewPane(item: item, store: viewModel.store,
                        hideSecrets: viewModel.settings.hideSecrets,
                        secretsRevealed: viewModel.revealedSecretIDs.contains(item.uuid),
                        onToggleSecrets: { viewModel.toggleSecretsRevealed(item) })
        }
    }
}

/// The rule between the leading favorites and the rest, the list's version of the full
/// shelf's `FavoritesDivider`.
private struct MiniFavoritesDivider: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.8))
                .frame(height: 1)
        }
        .padding(.horizontal, 4)
        .accessibilityLabel("Favorites divider")
    }
}

/// One history item in the mini shelf. Mirrors `ItemCardView`'s inputs and actions (the
/// same right-click menu, drag chip and click handling) in a compact row.
private struct MiniItemRow: View {
    let item: ClipItem
    let isSelected: Bool
    let isInlineRenaming: Bool
    let store: ItemStore
    let pinboards: [Pinboard]
    let currentPinboardID: Int64?
    let favoritesEnabled: Bool
    /// Lines of text the row shows, from the mini shelf's size.
    let previewLines: Int
    let isFlashing: Bool
    let hideSecrets: Bool
    let secretsRevealed: Bool
    let pasteNumber: Int?
    let canShowInHistory: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onHoverChanged: (Bool) -> Void
    let onPaste: () -> Void
    let onPastePlain: () -> Void
    let onEdit: () -> Void
    let onAdjustColor: () -> Void
    let onBeginInlineRename: () -> Void
    let onCommitInlineRename: (String) -> Void
    let onCancelInlineRename: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleSecrets: () -> Void
    let onAddToPinboard: (Int64) -> Void
    let onRemoveFromPinboard: () -> Void
    let onAddToPasteStack: () -> Void
    let onSplitToPasteStack: () -> Void
    let onCopyText: () -> Void
    let onQuickLook: () -> Void
    let onOpen: () -> Void
    let onShowInHistory: () -> Void
    let onRotate: (Bool) -> Void
    let onDelete: () -> Void
    let dragProvider: () -> NSItemProvider
    let dragBadgeCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private static let bodyCap = 1_500

    private var masksSecrets: Bool { hideSecrets && !secretsRevealed }

    private var isEditable: Bool {
        switch item.kind {
        case .text, .richText, .link: return true
        case .image, .file, .color: return false
        }
    }

    /// Earns the row its eye button. Only evaluated while the actions show.
    private var hasSecret: Bool {
        guard hideSecrets, isEditable, let text = item.plainText else { return false }
        return SecretDetector.maskedPrefix(text, count: Self.bodyCap) != String(text.prefix(Self.bodyCap))
    }

    private func displayText(_ text: String) -> String {
        masksSecrets ? SecretDetector.maskedPrefix(text, count: Self.bodyCap) : String(text.prefix(Self.bodyCap))
    }

    /// The custom title if set; otherwise "Image" for images, or the source app.
    private var headerLabel: String {
        if let title = item.title, !title.isEmpty { return title }
        if item.kind == .image { return "Image" }
        return item.appName ?? "Unknown"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingIcon
            VStack(alignment: .leading, spacing: 3) {
                header
                content
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2.5)
                .opacity(isFlashing ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isFlashing)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            onHoverChanged(hovering)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72), value: isSelected)
        .contextMenu {
            CardContextMenu(
                item: item, pinboards: pinboards, currentPinboardID: currentPinboardID,
                favoritesEnabled: favoritesEnabled, canShowInHistory: canShowInHistory,
                hasQuickLook: item.kind == .file && !QuickLookController.fileURLs(for: item, store: store).isEmpty,
                onPaste: onPaste, onPastePlain: onPastePlain, onEdit: onEdit, onAdjustColor: onAdjustColor,
                onRename: onBeginInlineRename, onToggleFavorite: onToggleFavorite,
                onAddToPinboard: onAddToPinboard, onRemoveFromPinboard: onRemoveFromPinboard,
                onAddToPasteStack: onAddToPasteStack, onSplitToPasteStack: onSplitToPasteStack,
                onCopyText: onCopyText, onQuickLook: onQuickLook, onOpen: onOpen,
                onShowInHistory: onShowInHistory, onRotate: onRotate, onDelete: onDelete)
        }
        .onDrag(dragProvider) {
            CardDragPreview(item: item, masksSecrets: masksSecrets, badgeCount: dragBadgeCount)
        }
        .modifier(CardClickGesture(onClick: onClick))
    }

    @ViewBuilder private var leadingIcon: some View {
        Group {
            if item.kind == .image {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let icon = AppIconCache.icon(forBundleID: item.appBundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// Name and age; on hover or selection the age gives way to the small favorite and
    /// delete buttons, so they never sit over the text.
    private var header: some View {
        HStack(spacing: 4) {
            if isInlineRenaming {
                InlineTitleField(initialText: item.title ?? "", onCommit: onCommitInlineRename,
                                 onCancel: onCancelInlineRename)
            } else {
                Text(headerLabel)
                    .font(Tokens.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let pasteNumber {
                    Text("⌥\(pasteNumber)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                } else if isHovering || isSelected {
                    actions.transition(.opacity)
                } else {
                    if favoritesEnabled && item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(Tokens.relativeFormatter.localizedString(for: item.lastUsedAt, relativeTo: Date()))
                        .font(Tokens.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .frame(height: 16)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if hasSecret {
                smallButton(secretsRevealed ? "eye.slash" : "eye",
                            help: secretsRevealed ? "Hide secrets" : "Show secrets", action: onToggleSecrets)
            }
            if favoritesEnabled {
                smallButton(item.isFavorite ? "star.fill" : "star",
                            tint: item.isFavorite ? .yellow : .secondary,
                            help: item.isFavorite ? "Remove from favorites" : "Favorite",
                            action: onToggleFavorite)
            }
            smallButton("trash", help: "Delete", action: onDelete)
        }
    }

    private func smallButton(_ symbol: String, tint: Color = .secondary, help: String,
                             action: @escaping () -> Void) -> some View {
        IconButton(systemName: symbol, fontSize: 9, size: CGSize(width: 18, height: 16),
                   tint: tint, help: help, action: action)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text, .richText:
            if let hex = HexColor.normalized(item.plainText ?? "") {
                swatch(hex)
            } else {
                Text(displayText(item.plainText ?? ""))
                    .font(isCode ? Tokens.bodyMono : Tokens.cardBody)
                    .lineLimit(previewLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .link:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    LinkFaviconView(item: item, store: store)
                    Text(item.linkTitle ?? URL(string: item.plainText ?? "")?.host ?? "Link")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                if previewLines > 1 {
                    Text(displayText(item.plainText ?? ""))
                        .font(Tokens.bodyMono)
                        .foregroundStyle(.secondary)
                        .lineLimit(previewLines - 1)
                }
            }
        case .image:
            CardThumbnail(item: item, store: store)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        case .file:
            HStack(spacing: 6) {
                FileThumbnail(item: item, store: store, compact: true)
                    .frame(width: thumbnailSize.height, height: thumbnailSize.height)
                Text(item.plainText ?? "File")
                    .font(Tokens.cardBody)
                    .lineLimit(previewLines)
            }
        case .color:
            swatch(item.plainText ?? "")
        }
    }

    /// Grows with the preview lines, so every size keeps its rhythm.
    private var thumbnailSize: CGSize {
        CGSize(width: 48 + CGFloat(previewLines) * 16, height: 18 + CGFloat(previewLines) * 14)
    }

    private var isCode: Bool {
        CodeHighlightCache.shared.result(for: item.plainText ?? "", uuid: item.uuid, cap: Self.bodyCap).language != nil
    }

    private func swatch(_ hex: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Tokens.color(fromHex: hex))
                .frame(width: 22, height: 16)
            Text(hex).font(Tokens.cardBody)
        }
    }
}
