import AppKit
import CopyCore
import SwiftUI

/// Hosts `SettingsView` in a standard titled window that `AppCoordinator` owns and
/// shows directly, rather than through SwiftUI's `Settings` scene.
///
/// Hands-on testing showed the `Settings` scene doesn't work for Copy's configuration:
/// Copy has no `WindowGroup` (it's a menu-bar-only, `LSUIElement` app), and in that
/// shape `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
/// reports `handled == true` but never actually creates a window: `NSApp.windows`
/// only ever contained the status item's own `NSStatusBarWindow` and its transient
/// `NSPopupMenuWindow`, confirmed by instrumenting the call and watching window close
/// notifications across several delays. Managing the window ourselves (the same
/// approach `ShelfPanelController` already uses for the shelf) sidesteps that
/// reflection-based mechanism entirely and needs no activation-policy tricks: a plain
/// titled `NSWindow` shows fine for an accessory app; only the Dock icon is restricted.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(settings: SettingsStore, store: ItemStore) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, store: store))
        // The redesigned settings is a `NavigationSplitView`, which fills its container
        // rather than reporting an intrinsic size — so let the window drive sizing, not the
        // hosting controller. `SettingsView` carries its own `.frame(minWidth:minHeight:)`,
        // and the explicit content/min sizes below give a real starting frame (avoiding the
        // 1pt sliver the old intrinsic-size path was needed to dodge for the TabView).
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.appearance = settings.shelfTheme.appearance
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.setContentSize(NSSize(width: 720, height: 520))
        self.init(window: window)
    }

    func setTheme(_ theme: ShelfTheme) {
        window?.appearance = theme.appearance
    }

    func show() {
        // Only center on first appearance — recentering on every reopen would undo a
        // user-moved window position.
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
