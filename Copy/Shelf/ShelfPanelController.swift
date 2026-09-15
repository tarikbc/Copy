import AppKit
import CopyCore

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// SwiftUI's `.popover()` presents its content in a separate `NSWindow` attached to
    /// this one via `addChildWindow` — a different window than the panel itself, so
    /// merely setting the panel's own `sharingType` doesn't exclude it from capture.
    /// Whoever owns this panel (`ShelfPanelController`/`PasteStackController`) keeps this
    /// in sync with its own `sharingType` policy; every child window attached from then
    /// on inherits it here, before `super.addChildWindow` orders it on screen.
    var childWindowSharingType: NSWindow.SharingType = .readOnly

    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        childWin.sharingType = childWindowSharingType
        super.addChildWindow(childWin, ordered: place)
    }
}

/// Keeps the shelf's contents inside the panel while they slide. This matters when the
/// shelf lives on a display with another display below it: moving the window itself past
/// the upper display's edge makes it visible on the lower one, while moving this child
/// view is clipped to the stationary window.
private final class ShelfClippingView: NSView {
    let shelfContent: NSView

    init(content: NSView) {
        shelfContent = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(content)
        content.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        var contentFrame = shelfContent.frame
        contentFrame.size = bounds.size
        shelfContent.frame = contentFrame
    }
}

@MainActor
final class ShelfPanelController: NSObject, NSWindowDelegate {
    static let shelfHeight: CGFloat = 352
    /// Panel height while `SettingsStore.compactShelf` is on, sized to `Tokens.compactCardHeight`
    /// plus the same header/divider/padding chrome `shelfHeight` allows for above the
    /// (shorter) card row. `ShelfHeader` isn't shortened in compact mode, so the fixed
    /// chrome above the card row (header + divider + `ShelfItemsRow`'s own vertical
    /// padding) is ~229pt; 232 left only ~3pt of margin before cards could clip against
    /// the panel's bottom edge, so this carries the same ~7% margin `shelfHeight` gives
    /// the standard card row.
    static let compactShelfHeight: CGFloat = 244

    var onKeyEvent: ((NSEvent) -> Bool)?
    /// Called on every modifier-key change while the shelf is open (⌘-hold hints).
    var onFlagsChanged: ((NSEvent) -> Void)?
    /// Called once when a force-click (pressure stage 2) begins over the shelf.
    var onForceClick: (() -> Void)?
    private var lastPressureStage = 0
    var onDidHide: (() -> Void)?

    private let makeContent: () -> NSView
    private var panel: KeyablePanel?
    private var modalPanel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    /// Guards the animated close until the panel is actually ordered out.
    private var isHiding = false
    /// Actions requested while the same close is in flight. They must wait for `orderOut`
    /// and focus restoration just like the action that initiated the close.
    private var pendingHideCompletions: [() -> Void] = []
    /// Bumped by both `show()` and each `hide()` so a stale close animation's completion
    /// handler doesn't order the panel out after a newer show/hide has superseded it.
    private var closeToken = 0
    private var hideDuringScreenSharing: Bool
    private var floatingShelf: Bool
    private var compactShelf: Bool
    private var proDark: Bool

    init(hideDuringScreenSharing: Bool, compactShelf: Bool, floatingShelf: Bool, proDark: Bool, makeContent: @escaping () -> NSView) {
        self.hideDuringScreenSharing = hideDuringScreenSharing
        self.compactShelf = compactShelf
        self.floatingShelf = floatingShelf
        self.proDark = proDark
        self.makeContent = makeContent
    }

    /// Pushed live by `AppCoordinator` via `SettingsStore.onShelfProDarkChange`. Forces
    /// the panel (and its hosted SwiftUI content) to a dark appearance so the whole shelf
    /// matches the marketing "pro dark" look; `nil` returns to following the system.
    func setProDark(_ on: Bool) {
        proDark = on
        panel?.appearance = on ? NSAppearance(named: .darkAqua) : nil
    }

    private var currentShelfHeight: CGFloat {
        compactShelf ? Self.compactShelfHeight : Self.shelfHeight
    }

    /// Applied at panel creation and pushed live here when the setting changes
    /// (`AppCoordinator` wires `SettingsStore.onHideDuringScreenSharingChange`). `.none`
    /// excludes the panel from screen recordings/captures/shares; `.readOnly` is
    /// AppKit's normal default (content visible, not modifiable by other processes).
    func setHideDuringScreenSharing(_ hide: Bool) {
        hideDuringScreenSharing = hide
        panel?.sharingType = hide ? .none : .readOnly
        panel?.childWindowSharingType = hide ? .none : .readOnly
    }

    /// Pushed live by `AppCoordinator` via `SettingsStore.onCompactShelfChange`. Updates
    /// the height used on the next `show()` and, if the panel is already visible,
    /// resizes it immediately so toggling the setting doesn't need a close/reopen —
    /// mirrors `setHideDuringScreenSharing`'s live-update shape above.
    func setCompactShelf(_ compact: Bool) {
        compactShelf = compact
        guard isVisible, let panel,
              let screen = NSScreen.screens.first(where: {
                  NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
              }) ?? NSScreen.main else { return }
        let frame = ShelfLayout.frame(visibleFrame: screen.visibleFrame, height: currentShelfHeight, floating: floatingShelf)
        panel.setFrame(frame, display: true)
    }

    func setFloatingShelf(_ floating: Bool) {
        floatingShelf = floating
        guard let panel, panel.isVisible, !isHiding, let screen = panel.screen else { return }
        setShelfContentOffset(0, in: panel)
        panel.setFrame(ShelfLayout.frame(visibleFrame: screen.visibleFrame,
                                        height: currentShelfHeight, floating: floating), display: true)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide(restoreFocus: true) : show()
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let frame = ShelfLayout.frame(visibleFrame: screen.visibleFrame, height: currentShelfHeight, floating: floatingShelf)
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Cancel any in-flight close: invalidate its completion token and drop the guard so
        // re-summoning mid-close animates straight back in.
        closeToken += 1
        isHiding = false
        // Whatever was queued behind that close is cancelled with it. Only `finishHide`
        // drains this, and the superseded animation never reaches it, so a survivor would
        // sit here and fire at the *next* close: a paste the screener asked for before
        // re-opening the shelf, landing in whatever app is frontmost seconds later.
        // Re-summoning the shelf is them changing their mind, so drop it.
        pendingHideCompletions.removeAll()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setShelfContentOffset(0, in: panel)
        if floatingShelf {
            // Keep the window on its display: only its clipped content slides, so it
            // cannot leak onto another monitor placed below this one.
            panel.setFrame(frame, display: false)
            panel.alphaValue = 1
            setShelfContentOffset(reduceMotion ? 0 : -frame.height, in: panel)
            panel.makeKeyAndOrderFront(nil)
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    shelfContentView(in: panel)?.animator().setFrameOrigin(.zero)
                }
            }
        } else {
            panel.setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: -24), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        }
        installKeyMonitor()
        // The shelf opens in browse mode: keep the search field from auto-becoming first
        // responder when the panel keys up (AppKit picks the first text field otherwise).
        // Clear it now and again after SwiftUI's first layout pass, which can set it late.
        // Type-to-search (the global key monitor) still works with nothing focused.
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak panel] in panel?.makeFirstResponder(nil) }
    }

    func hide(restoreFocus: Bool, completion: (() -> Void)? = nil) {
        guard let panel, isVisible else {
            completion?()
            return
        }
        if let completion {
            pendingHideCompletions.append(completion)
        }
        // A repeated action during the 180ms fade joins the current close instead of
        // being dropped or running before the destination app regains focus.
        guard !isHiding else { return }
        // Keep Copy active until the panel is fully out. On macOS 26 the shelf is live
        // Liquid Glass; activating the previous app while that glass is still visible
        // changes its sampled backdrop mid-fade and produces a one-frame flash.
        isHiding = true
        removeKeyMonitor()

        // Mirror of `show()`'s entrance: fade out while sliding down 18pt, then order out.
        // Reduce Motion skips straight to the orderOut, matching the entrance's own gate.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishHide(panel, restoreFocus: restoreFocus)
            return
        }

        closeToken += 1
        let token = closeToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = floatingShelf ? 0.13 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if floatingShelf {
                shelfContentView(in: panel)?.animator().setFrameOrigin(NSPoint(x: 0, y: -panel.frame.height))
            } else {
                panel.animator().alphaValue = 0
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -18), display: true)
            }
        } completionHandler: { [weak self] in
            // NSAnimationContext runs its completion on the main thread; the closure's
            // `@Sendable` type just can't see that statically.
            MainActor.assumeIsolated {
                guard let self, self.closeToken == token else { return }
                self.finishHide(panel, restoreFocus: restoreFocus)
            }
        }
    }

    /// Orders the panel out and resets it so the next `show()` starts clean. `onDidHide`
    /// (which clears the shelf's transient selection/preview state) fires here, at the end
    /// of the close animation, so that content doesn't visibly reset while the panel is
    /// still fading out.
    private func finishHide(_ panel: KeyablePanel, restoreFocus: Bool) {
        panel.orderOut(nil)
        setShelfContentOffset(0, in: panel)
        // Leave alpha at zero while hidden. Resetting it to one in the same run-loop
        // turn as `orderOut` can race WindowServer and briefly re-show the fully opaque
        // surface. `show()` always establishes its own alpha-zero starting state.
        isHiding = false
        onDidHide?()
        if restoreFocus {
            previousApp?.activate()
        }
        let completions = pendingHideCompletions
        pendingHideCompletions.removeAll()
        completions.forEach { $0() }
    }

    // MARK: - Private

    private func shelfContentView(in panel: KeyablePanel) -> NSView? {
        (panel.contentView as? ShelfClippingView)?.shelfContent
    }

    private func setShelfContentOffset(_ offset: CGFloat, in panel: KeyablePanel) {
        shelfContentView(in: panel)?.setFrameOrigin(NSPoint(x: 0, y: offset))
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = proDark ? NSAppearance(named: .darkAqua) : nil
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.contentView = ShelfClippingView(content: makeContent())
        panel.sharingType = hideDuringScreenSharing ? .none : .readOnly
        panel.childWindowSharingType = hideDuringScreenSharing ? .none : .readOnly
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .pressure]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.type {
            case .keyDown:
                return (self.onKeyEvent?(event) ?? false) ? nil : event
            case .flagsChanged:
                self.onFlagsChanged?(event)
                return event
            case .pressure:
                // Fire once as the press crosses into the force-click stage (2), not on
                // every pressure sample while it's held.
                if event.stage >= 2, self.lastPressureStage < 2 {
                    self.onForceClick?()
                }
                self.lastPressureStage = event.stage
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if NSApp.modalWindow != nil { return }
        if let key = NSApp.keyWindow, let panel,
           panel.childWindows?.contains(key) == true || panel.attachedSheet === key {
            return
        }
        hide(restoreFocus: false)
    }

    /// SwiftUI's `.sheet()` (Edit/Create/Rename/Adjust Color/Tips) presents via AppKit's
    /// sheet mechanism rather than `addChildWindow`, so `KeyablePanel.childWindowSharingType`
    /// doesn't catch it — this documented `NSWindowDelegate` hook fires as the sheet is
    /// attached to `window` (the panel), before it's positioned/shown, giving a
    /// deterministic point to apply the same policy AND to reposition the sheet.
    ///
    /// The shelf panel sits at the screen bottom, so a sheet dropped from its top edge
    /// (the default) overflows off the bottom of the screen for anything tall. Raise the
    /// sheet's top so the whole sheet sits *above* the panel instead, clamped to stay on
    /// screen. The returned rect's top, in window coordinates, is where the sheet's top
    /// edge is placed; the sheet then extends downward by its own height.
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        sheet.sharingType = hideDuringScreenSharing ? .none : .readOnly
        return rect
    }

    /// Shows the modal content (edit/create/color/tips) as a full-screen child window
    /// centered on the shelf's screen, so it's fully visible above the shelf instead of
    /// overflowing off the bottom as an attached sheet does. A *child* window (not a
    /// separate panel) keeps `windowDidResignKey` from hiding the shelf underneath.
    func presentModal(_ view: NSView) {
        let host = modalPanel ?? makeModalPanel()
        host.contentView = view
        if let screen = panel?.screen ?? NSScreen.main {
            host.setFrame(screen.frame, display: true)
        }
        if let panel, host.parent !== panel {
            panel.addChildWindow(host, ordered: .above)
        }
        host.makeKeyAndOrderFront(nil)
    }

    func dismissModal() {
        guard let host = modalPanel else { return }
        panel?.removeChildWindow(host)
        host.orderOut(nil)
        panel?.makeKey()
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
        host.sharingType = hideDuringScreenSharing ? .none : .readOnly
        modalPanel = host
        return host
    }
}
