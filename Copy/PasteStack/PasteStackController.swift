import AppKit
import CopyCore
import SwiftUI

/// Floating Paste Stack palette. Unlike `ShelfPanelController`, this panel must never
/// activate the app or become key — the whole point of the stack is that plain ⌘V
/// keeps going to the frontmost app while the palette floats on top (Task 7's CGEvent
/// tap intercepts that keystroke). So `show()` only calls `orderFrontRegardless()`,
/// never `makeKeyAndOrderFront`/`NSApp.activate`. `.nonactivatingPanel` panels still
/// deliver mouse events (button clicks, list drag-reorder) without becoming key or
/// stealing focus, which is what makes the palette interactive despite that.
@MainActor
final class PasteStackController {
    static let width: CGFloat = 280
    static let maxHeight: CGFloat = 420
    static let inset: CGFloat = 16

    private let model: PasteStackModel
    private var panel: KeyablePanel?
    // Separate key-capable child window that hosts the rich `EditItemSheet` when a row's
    // pencil is tapped. The palette panel itself must never become key (⌘V would then paste
    // into Copy), so editing happens in this window, which can take keyboard focus — the
    // same split the shelf uses (`ShelfPanelController.presentModal`).
    private var modalPanel: KeyablePanel?
    private var hideDuringScreenSharing: Bool
    private var theme: ShelfTheme

    init(model: PasteStackModel, hideDuringScreenSharing: Bool, theme: ShelfTheme) {
        self.model = model
        self.hideDuringScreenSharing = hideDuringScreenSharing
        self.theme = theme
    }

    /// Updates the palette and any open editor. Cached hidden palettes rebuild their
    /// content on next open, preserving the existing accent-refresh behavior.
    func setTheme(_ theme: ShelfTheme) {
        self.theme = theme
        modalPanel?.appearance = theme.appearance
        if let panel, panel.isVisible {
            panel.appearance = theme.appearance
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    /// Applied at panel creation and pushed live here when the setting changes
    /// (`AppCoordinator` wires `SettingsStore.onHideDuringScreenSharingChange`). `.none`
    /// excludes the palette from screen recordings/captures/shares; `.readOnly` is
    /// AppKit's normal default (content visible, not modifiable by other processes).
    func setHideDuringScreenSharing(_ hide: Bool) {
        hideDuringScreenSharing = hide
        panel?.sharingType = hide ? .none : .readOnly
        panel?.childWindowSharingType = hide ? .none : .readOnly
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Single entry point for palette visibility, wired to `model.onActiveChange` by
    /// `AppCoordinator`. Also fine to call directly (e.g. from `show()`'s own
    /// content-change hook) since both `show()` and `hide()` are idempotent.
    func syncVisibility(to isActive: Bool) {
        if isActive {
            show()
        } else {
            hide()
        }
    }

    /// Shows the palette at the top-right of the mouse's screen, sized to fit the
    /// current queue (capped at `maxHeight`). Only positions fresh when the panel isn't
    /// already visible — once the user has moved/is looking at the palette, content
    /// changes must not teleport it back to the corner; that's what `resizeToFit()`
    /// (wired to `PasteStackView.onContentChange`) is for.
    func show() {
        // Drop any queued uuid that's gone missing (deleted/pruned) since being
        // queued. `PasteStackModel.items()` is a pure read used from SwiftUI bodies,
        // so this explicit event point — the palette becoming visible — is where that
        // bookkeeping actually happens.
        model.reconcile()

        let panel = self.panel ?? makePanel()
        self.panel = panel

        guard !panel.isVisible else {
            resizeToFit()
            return
        }

        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let height = computeHeight()
        let frame = NSRect(
            x: screen.visibleFrame.maxX - Self.width - Self.inset,
            y: screen.visibleFrame.maxY - height - Self.inset,
            width: Self.width,
            height: height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Re-fits the palette's height to the current queue while keeping its current
    /// on-screen position, anchored at the current top edge. Called from
    /// `PasteStackView.onContentChange` (items added/removed/reordered) so the palette
    /// doesn't jump back to the top-right corner on every copy while the stack is
    /// active — only `show()`'s fresh-activation path positions there. AppKit frames
    /// are bottom-left-anchored, so holding the top edge fixed while the height changes
    /// means recomputing the origin's y: `newOriginY = currentTopY - newHeight`.
    private func resizeToFit() {
        guard let panel, panel.isVisible else { return }
        let current = panel.frame
        let currentTopY = current.origin.y + current.height
        let newHeight = computeHeight()
        let newFrame = NSRect(
            x: current.origin.x,
            y: currentTopY - newHeight,
            width: current.width,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true)
    }

    private func computeHeight() -> CGFloat {
        let count = model.items().count
        let header: CGFloat = 34
        // Empty palette has no footer (order picker + Clear are hidden), so it's just the
        // header, a divider, and the compact empty state.
        if count == 0 {
            return header + 1 + 120
        }
        let dividers: CGFloat = 2
        let footer: CGFloat = 82
        let content: CGFloat = CGFloat(count) * PasteStackView.rowHeight + 8
        return min(max(header + dividers + footer + content, 180), Self.maxHeight)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = theme.appearance
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        // Off: the window is dragged explicitly from the header (WindowDragArea →
        // performDrag), so dragging a list row is free to reorder it. See PasteStackView.
        panel.isMovableByWindowBackground = false
        panel.sharingType = hideDuringScreenSharing ? .none : .readOnly
        panel.childWindowSharingType = hideDuringScreenSharing ? .none : .readOnly

        // The panel's contentView is a real NSVisualEffectView, not the SwiftUI
        // `.glassEffect`: on macOS 26 that effect has no backing NSView, so the empty areas
        // of this non-key panel let clicks fall through to the app behind. A visual-effect
        // view is a real view that absorbs every click over its frame while still reading as
        // dark glass, consistent with the shelf. The SwiftUI content sits on top of it.
        let hosting = NSHostingView(rootView: PasteStackView(
            model: model,
            onClose: { [weak model] in model?.isActive = false },
            onEdit: { [weak self] item in self?.presentEditor(for: item) },
            // Defer to the next runloop tick: the + button mutates the queue from inside a
            // SwiftUI update, and resizing the panel (setFrame) synchronously there would
            // re-enter SwiftUI's layout pass mid-update and corrupt the window. Adds from
            // outside the view (the paste-stack hotkey) don't hit that, but deferring is
            // safe for them too.
            onContentChange: { [weak self] in
                DispatchQueue.main.async { self?.resizeToFit() }
            }
        )
        .tint(theme == .dark ? Tokens.electricBlue : nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // The material view (a real NSView) makes every pixel non-transparent, so the
        // window server stops passing clicks through the panel to the app behind — the
        // actual root cause of the click-through under macOS 26's backing-view-less glass.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        // A plain container as the contentView, with the material behind and the SwiftUI
        // content in front, both pinned to it. Pinning the hosting view to a plain view
        // (not to the material view itself) keeps its layout correct — no clipped header.
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(effect)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        panel.hasShadow = true
        return panel
    }

    // MARK: Rich editor

    /// Opens the rich `EditItemSheet` for `item` in a full-screen, dim-backed child window
    /// centered on the palette's screen — the same modal-host approach as the shelf. The
    /// palette panel can't host it (it must stay non-key), so this window becomes key and
    /// Copy activates briefly so the editor's text view can take keyboard focus; both are
    /// yielded back on dismiss.
    private func presentEditor(for item: ClipItem) {
        let host = modalPanel ?? makeModalPanel()
        host.contentView = NSHostingView(rootView: PasteStackEditorHost(
            item: item,
            store: model.store,
            theme: theme,
            onCancel: { [weak self] in self?.dismissEditor() },
            onSave: { [weak self] attributed in
                self?.model.commitEdit(attributed, for: item)
                self?.dismissEditor()
            }
        ))
        if let screen = panel?.screen ?? NSScreen.main {
            host.setFrame(screen.frame, display: true)
        }
        if let panel, host.parent !== panel {
            panel.addChildWindow(host, ordered: .above)
        }
        NSApp.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
    }

    /// Tears down the editor window and hands active status back to the app the user was
    /// working in, so plain ⌘V resumes pasting there (the palette panel stays non-key).
    private func dismissEditor() {
        guard let host = modalPanel else { return }
        panel?.removeChildWindow(host)
        host.orderOut(nil)
        NSApp.deactivate()
    }

    private func makeModalPanel() -> KeyablePanel {
        let host = KeyablePanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        host.level = .statusBar
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.hidesOnDeactivate = false
        host.appearance = theme.appearance
        host.sharingType = hideDuringScreenSharing ? .none : .readOnly
        modalPanel = host
        return host
    }
}
