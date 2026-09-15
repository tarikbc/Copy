import AppKit
import CopyCore
import SwiftUI

/// Content of the floating Paste Stack palette. The palette is a non-activating, never-key
/// panel (so plain ⌘V keeps pasting into the app underneath — see `PasteStackEngine`), and
/// its panel `contentView` is a real `NSVisualEffectView` that captures every click, so the
/// SwiftUI here can stay simple. Rows are a fixed-height `ScrollView`; reorder is a direct
/// drag gesture (no drag-and-drop system, which needs window focus). Entries can be added
/// (header +, queues the latest copy), edited in the rich `EditItemSheet` (double-click /
/// pencil, via `onEdit` → `PasteStackController.presentEditor`), removed (trash on hover /
/// context menu), reordered by dragging, and cleared (header trash).
struct PasteStackView: View {
    @Bindable var model: PasteStackModel
    var onClose: () -> Void = {}
    var onEdit: (ClipItem) -> Void = { _ in }
    var onContentChange: () -> Void = {}

    @State private var draggingUUID: String?
    @State private var dragTranslation: CGFloat = 0

    static let rowHeight: CGFloat = 36

    /// Reads `model.revision` (so an in-place edit re-renders) and resolves the queue's
    /// uuids to items once per body evaluation.
    private var resolvedItems: [ClipItem] {
        _ = model.revision
        return model.items()
    }

    var body: some View {
        let items = resolvedItems
        VStack(spacing: 0) {
            header(count: items.count)
            Divider().opacity(0.6)
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    list(items: items)
                }
            }
            .frame(maxHeight: .infinity)
            if !items.isEmpty {
                Divider().opacity(0.6)
                footer
            }
        }
        // Top-anchored: the header stays pinned to the top no matter how the panel height
        // and the content height drift — any mismatch shows as space below the footer, never
        // a clipped header.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.queue.itemUUIDs) { _, _ in onContentChange() }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Paste Stack")
                .font(.system(size: 13, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            }
            Spacer(minLength: 8)
            if count > 0 {
                IconButton(systemName: "trash", help: "Clear the stack") { model.queue.clear() }
            }
            IconButton(systemName: "plus", help: "Add the latest copy") { model.addMostRecent() }
            IconButton(systemName: "xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The header is the palette's drag handle; the buttons on top take their own clicks.
        .background(WindowDragArea())
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing queued")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add a copy with +, then ⌘V walks the stack.")
                .font(Tokens.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 16)
    }

    // MARK: List

    private func list(items: [ClipItem]) -> some View {
        let order = pasteNumbers(for: items)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.uuid) { index, item in
                    PasteStackRow(
                        item: item,
                        number: order[item.uuid] ?? 0,
                        isNext: order[item.uuid] == 1,
                        isDragging: draggingUUID == item.uuid,
                        isEditable: isEditable(item),
                        onEdit: { onEdit(item) },
                        onRemove: { model.queue.remove(item.uuid) }
                    )
                    .frame(height: Self.rowHeight)
                    .offset(y: dragYOffset(uuid: item.uuid, index: index, items: items))
                    .zIndex(draggingUUID == item.uuid ? 1 : 0)
                    .gesture(reorderGesture(item: item, items: items))
                    .contextMenu {
                        if isEditable(item) {
                            Button("Edit…") { onEdit(item) }
                        }
                        Button("Remove", role: .destructive) { model.queue.remove(item.uuid) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Reorder (direct drag, no drag-and-drop system)

    private func reorderGesture(item: ClipItem, items: [ClipItem]) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if draggingUUID == nil { draggingUUID = item.uuid }
                dragTranslation = value.translation.height
            }
            .onEnded { _ in
                defer { draggingUUID = nil; dragTranslation = 0 }
                guard let dragging = draggingUUID,
                      let source = items.firstIndex(where: { $0.uuid == dragging }) else { return }
                let target = clampedTarget(source: source, count: items.count)
                if target != source { model.queue.move(from: source, to: target) }
            }
    }

    private func clampedTarget(source: Int, count: Int) -> Int {
        let delta = Int((dragTranslation / Self.rowHeight).rounded())
        return min(max(source + delta, 0), count - 1)
    }

    private func dragYOffset(uuid: String, index: Int, items: [ClipItem]) -> CGFloat {
        guard let dragging = draggingUUID,
              let source = items.firstIndex(where: { $0.uuid == dragging }) else { return 0 }
        if uuid == dragging { return dragTranslation }
        let target = clampedTarget(source: source, count: items.count)
        if source < target, index > source, index <= target { return -Self.rowHeight }
        if source > target, index < source, index >= target { return Self.rowHeight }
        return 0
    }

    // MARK: Edit

    private func isEditable(_ item: ClipItem) -> Bool {
        switch item.kind {
        case .text, .richText, .link: return true
        case .image, .file, .color: return false
        }
    }

    /// Maps each item's uuid to its 1-based paste position. Row 1 is whatever Command V
    /// pastes next: the first-added under "Oldest first" (FIFO) or the last-added under
    /// "Newest first" (LIFO). `model.items()` is in insertion order, so LIFO numbers from
    /// the bottom up.
    private func pasteNumbers(for items: [ClipItem]) -> [String: Int] {
        let isLIFO = model.queue.isLIFO
        var map: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            map[item.uuid] = isLIFO ? (items.count - index) : (index + 1)
        }
        return map
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Picker("Paste order", selection: $model.queue.isLIFO) {
                Text("Oldest first").tag(false)
                Text("Newest first").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Paste order")

            Text("⌘V pastes the next item · drag to reorder")
                .font(Tokens.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PasteStackRow: View {
    let item: ClipItem
    let number: Int
    let isNext: Bool
    var isDragging: Bool = false
    var isEditable: Bool = true
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isNext ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isNext ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                )

            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(item.displayTitle)
                .font(Tokens.bodyMono)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovering {
                HStack(spacing: 1) {
                    // Only text-like rows can be edited; images/files/colors show just Remove.
                    if isEditable {
                        IconButton(systemName: "pencil", fontSize: 10,
                                   size: CGSize(width: 22, height: 22), help: "Edit", action: onEdit)
                    }
                    IconButton(systemName: "trash", fontSize: 10,
                               size: CGSize(width: 22, height: 22), help: "Remove", action: onRemove)
                }
            } else if isNext {
                Text("Next")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDragging ? Color.primary.opacity(0.1) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        )
        .shadow(color: isDragging ? .black.opacity(0.2) : .clear, radius: isDragging ? 6 : 0, y: 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if isEditable { onEdit() } }
    }

    private var glyph: String {
        switch item.kind {
        case .text, .richText: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }
}

/// Full-screen host for the paste-stack rich editor: a dim backdrop with the shared
/// `EditItemSheet` centered on top, mirroring `ShelfModalHostView`. Lives in the
/// controller's key-capable child window (`PasteStackController.presentEditor`) so the
/// editor's text view can take focus without the palette panel ever becoming key.
struct PasteStackEditorHost: View {
    let item: ClipItem
    let store: ItemStore
    var theme: ShelfTheme
    let onCancel: () -> Void
    let onSave: (NSAttributedString) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
            EditItemSheet(item: item, store: store, onCancel: onCancel, onSave: onSave)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(theme == .dark ? Tokens.electricBlue : nil)
    }
}
