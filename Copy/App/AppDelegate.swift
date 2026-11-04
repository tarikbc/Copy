import AppKit
import CopyCore
import KeyboardShortcuts
import Quartz
import Sparkle

extension KeyboardShortcuts.Name {
    static let toggleShelf = Self("toggleShelf", initial: .init(.v, modifiers: [.command, .shift]))
    static let togglePasteStack = Self("togglePasteStack", initial: .init(.c, modifiers: [.command, .shift]))
    static let pasteNextFromStack = Self("pasteNextFromStack", initial: .init(.n, modifiers: [.control, .option, .command]))
    /// No default shortcut — the user opts in from Settings. Pastes the most recent
    /// history item directly into the frontmost app without opening the shelf.
    static let quickPasteLatest = Self("quickPasteLatest")
    /// No default shortcut — the user opts in from Settings. Advances the shelf's
    /// active tab to the next pinboard while the shelf is open.
    static let nextPinboard = Self("nextPinboard")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Optional so `SettingsStore.hideMenuBarIcon` can remove it live — see
    /// `applyHideMenuBarIconSetting`. `nil` means no status item exists right now.
    private var statusItem: NSStatusItem?
    private var coordinator: AppCoordinator!
    private var handlingExternalBatch = false
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                                   updaterDelegate: nil,
                                                                   userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(pasteStackPing(_:withReplyEvent:)),
                                                      forEventClass: 0x43705374, andEventID: 0x70696e67)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(pasteStackBatch(_:withReplyEvent:)),
                                                      forEventClass: 0x43705374, andEventID: 0x62617463)
    }

    @objc private func pasteStackPing(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        pasteStackReply(coordinator?.settings.allowsExternalPasteStackRequests() == true ? "capable" : "disabled", to: reply)
    }

    @objc private func pasteStackBatch(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let wallTime = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let payload = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              payload.descriptorType == DescType(typeUTF8Text),
              let descriptor = payload.aeDesc, AEGetDescDataSize(descriptor) <= 6_295_552,
              let request = PasteStackBatchRequest.decode(payload.data, now: wallTime) else {
            pasteStackReply("invalid", to: reply)
            return
        }
        guard !request.isExpired(at: wallTime) else {
            pasteStackReply("expired", to: reply)
            return
        }
        pasteStackReply(acceptPasteStackBatch(request.items, caller: pasteStackCaller(from: event),
                                              deadline: request.monotonicDeadline(wallTime: wallTime, uptime: uptime)), to: reply)
    }

    private func pasteStackReply(_ status: String, to reply: NSAppleEventDescriptor) {
        let data = Data("{\"version\":1,\"status\":\"\(status)\"}".utf8)
        guard let value = NSAppleEventDescriptor(descriptorType: DescType(typeUTF8Text), data: data) else { return }
        reply.setParam(value, forKeyword: AEKeyword(keyDirectObject))
    }

    func requestPasteStackBatch(_ texts: [String]) -> Bool {
        acceptPasteStackBatch(texts, caller: nil) == "accepted"
    }

    private func acceptPasteStackBatch(_ texts: [String], caller: PasteStackCaller?,
                                       deadline: TimeInterval? = nil) -> String {
        func expired() -> Bool {
            deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
        }
        guard !expired() else { return "expired" }
        guard !handlingExternalBatch, coordinator != nil else { return "busy" }
        guard coordinator.settings.allowsExternalPasteStackRequests() else { return "disabled" }
        var probe = PasteStackQueue()
        guard probe.replaceWithBatch(texts) else { return "invalid" }
        handlingExternalBatch = true
        defer { handlingExternalBatch = false }
        while !expired() {
            let trusted = caller.map { caller in
                coordinator.settings.pasteStackPermissions.contains { $0.permits(caller) }
            } ?? false
            let previous = coordinator.pasteStackSnapshot
            var rememberPermission: PasteStackPermission?
            if !trusted || !previous.isEmpty {
                let signed: PasteStackPermission?
                if let caller, let signingID = caller.signingID, let certificate = caller.certificateSHA256 {
                    signed = .signed(bundleID: caller.bundleID, signingID: signingID, certificateSHA256: certificate)
                } else {
                    signed = nil
                }
                let alert = pasteStackBatchConfirmation(texts, hideSecrets: coordinator.settings.hideSecrets,
                                                        hideDuringScreenSharing: coordinator.settings.hideDuringScreenSharing,
                                                        caller: pasteStackCallerDescription(caller),
                                                        canRemember: !trusted && signed != nil,
                                                        hasExistingItems: !previous.isEmpty)
                NSApp.activate(ignoringOtherApps: true)
                let decision = alert.runModal()
                guard decision == .alertSecondButtonReturn || (signed != nil && decision == .alertThirdButtonReturn) else {
                    return "cancelled"
                }
                guard !expired() else { return "expired" }
                if decision == .alertThirdButtonReturn { rememberPermission = signed }
            }
            guard !expired() else { return "expired" }
            guard coordinator.settings.allowsExternalPasteStackRequests() else { return "disabled" }
            if trusted, let caller,
               !coordinator.settings.pasteStackPermissions.contains(where: { $0.permits(caller) }) { continue }
            guard coordinator.replacePasteStack(with: texts, ifUnchanged: previous) else { continue }
            if let permission = rememberPermission,
               !coordinator.settings.pasteStackPermissions.contains(permission) {
                if !coordinator.settings.setPasteStackPermissions(coordinator.settings.pasteStackPermissions + [permission]) {
                    let alert = NSAlert()
                    alert.messageText = "Could not remember this app"
                    alert.informativeText = "The request was accepted, but Keychain access was unavailable. Future requests will ask for approval."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            return "accepted"
        }
        return "expired"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            coordinator = try AppCoordinator()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Copy could not open its database"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        applyHideMenuBarIconSetting(coordinator.settings.hideMenuBarIcon)
        coordinator.settings.onHideMenuBarIconChange = { [weak self] hide in
            self?.applyHideMenuBarIconSetting(hide)
        }
        // Third trigger for the anti-stranding guard: `hideMenuBarIcon` itself doesn't
        // change when the user clears the shelf summon hotkey from Settings, so
        // `onHideMenuBarIconChange` above never fires for that edit. Without this,
        // hiding the icon and then clearing the hotkey in the same session would leave
        // the user with neither the icon nor the hotkey — re-running the guard here
        // (it re-reads `KeyboardShortcuts.getShortcut` itself) restores the icon in
        // that case. See `SettingsStore.onShelfHotkeyChange`'s doc comment.
        coordinator.settings.onShelfHotkeyChange = { [weak self] in
            guard let self else { return }
            self.applyHideMenuBarIconSetting(self.coordinator.settings.hideMenuBarIcon)
        }

        coordinator.start()

        if !UserDefaults.standard.bool(forKey: "hasOnboarded") {
            coordinator.showOnboarding()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleShelf) { [weak self] in
            self?.coordinator.toggleShelf()
        }
        KeyboardShortcuts.onKeyDown(for: .togglePasteStack) { [weak self] in
            self?.coordinator.togglePasteStack()
        }
        // Fallback path only: `AppCoordinator` enables this while the Paste Stack is
        // active and the CGEvent tap couldn't be created (no Accessibility), and
        // disables it again on deactivation — see `pasteStackModel.onActiveChange`.
        KeyboardShortcuts.onKeyDown(for: .pasteNextFromStack) { [weak self] in
            self?.coordinator.pasteNextFromStack()
        }
        KeyboardShortcuts.disable(.pasteNextFromStack)
        KeyboardShortcuts.onKeyDown(for: .quickPasteLatest) { [weak self] in
            self?.coordinator.quickPasteLatest()
        }
        KeyboardShortcuts.onKeyDown(for: .nextPinboard) { [weak self] in
            self?.coordinator.selectNextPinboard()
        }

        // Bridged directly here rather than through `AppCoordinator`: the Sparkle
        // updater controller and `NSApp` are both owned/reachable at this layer, not
        // the coordinator's.
        coordinator.shelfViewModel.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        // Same bridge for the Settings > About "Check for Updates…" button.
        coordinator.settings.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        coordinator.shelfViewModel.onQuit = {
            NSApp.terminate(nil)
        }
    }

    /// Creates or removes the status item to honor `SettingsStore.hideMenuBarIcon`.
    /// Called at launch, live via `onHideMenuBarIconChange` (the setting itself
    /// flipping), and live via `onShelfHotkeyChange` (the shelf hotkey changing while
    /// the setting stays put) — three triggers feeding one authoritative check, so the
    /// guard below can't go stale under either kind of edit.
    ///
    /// Anti-stranding guard: hiding the icon must never leave the user with no way to
    /// reach Copy. The shelf's summon hotkey (`KeyboardShortcuts.Name.toggleShelf`,
    /// ⇧⌘V by default) is drawer-first's other entry point, so this refuses to honor
    /// `hide` — keeping the status item visible regardless — if that hotkey is unset.
    /// `GeneralSettings` mirrors this by disabling its "Hide the menu bar icon" toggle
    /// under the same condition, but this check is the actually-authoritative one.
    private func applyHideMenuBarIconSetting(_ hide: Bool) {
        let canHide = hide && KeyboardShortcuts.getShortcut(for: .toggleShelf) != nil
        if canHide {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
        } else if statusItem == nil {
            createStatusItem()
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The Duplicate mark as a monochrome menu-bar template: a front card with its copy
    /// stepped behind it, matching the app icon. A cleared gap between the two keeps them
    /// legible as two distinct cards at menu-bar size. `isTemplate` lets the menu bar
    /// tint it for light and dark automatically.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            func card(_ r: CGRect) -> CGPath {
                CGPath(roundedRect: r, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
            }
            let back = CGRect(x: 7, y: 6.4, width: 8.2, height: 10.2)
            let front = CGRect(x: 2.8, y: 1.8, width: 8.2, height: 10.2)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(card(back))
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.addPath(card(front.insetBy(dx: -1.1, dy: -1.1)))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.addPath(card(front))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.applicationWillTerminate()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Copy", action: #selector(openShelf), keyEquivalent: "V")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)
        let newItem = NSMenuItem(title: "New Item…", action: #selector(createItem), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(.separator())

        let items = coordinator.recentItems()
        if items.isEmpty {
            let empty = NSMenuItem(title: "No clipboard history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in items {
            let menuItem = NSMenuItem(title: item.displayTitle(hidingSecrets: coordinator.settings.hideSecrets),
                                      action: #selector(pasteMenuItem(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }

        // The management block below mirrors the shelf's drawer menu
        // (`DrawerMenu` in `ShelfRootView`) one-for-one — same actions, same order,
        // same grouping — so the two menus stay consistent. The only status-menu
        // extras are "Open Copy" and the live recent-items list above, which are
        // menu-bar-only by nature (the shelf is already open, and already shows items).
        menu.addItem(.separator())
        let pasteStack = NSMenuItem(title: "Paste Stack", action: #selector(togglePasteStack), keyEquivalent: "c")
        pasteStack.keyEquivalentModifierMask = [.command, .shift]
        pasteStack.target = self
        pasteStack.state = coordinator.isPasteStackActive ? .on : .off
        menu.addItem(pasteStack)
        let pause = NSMenuItem(title: coordinator.isPaused ? "Resume Monitoring" : "Pause Monitoring",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let export = NSMenuItem(title: "Export…", action: #selector(exportHistory), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        let importItem = NSMenuItem(title: "Import…", action: #selector(importHistory), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let checkForUpdates = NSMenuItem(title: "Check for Updates…",
                                         action: #selector(checkForUpdates(_:)),
                                         keyEquivalent: "")
        checkForUpdates.target = self
        menu.addItem(checkForUpdates)

        #if DEBUG
        menu.addItem(.separator())
        let demo = NSMenuItem(title: coordinator.isDemoMode ? "Exit Demo Mode" : "Enter Demo Mode",
                              action: #selector(toggleDemoMode), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)
        #endif

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Copy",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    #if DEBUG
    /// Flips the demo-mode flag and relaunches, so the app comes back up against the
    /// isolated demo (or real) database. DEBUG-only — never compiled into release.
    @objc private func toggleDemoMode() {
        let defaults = UserDefaults.standard
        defaults.set(!coordinator.isDemoMode, forKey: AppCoordinator.demoModeKey)
        defaults.synchronize()   // flush the flag before the fresh instance reads it back
        // Relaunch via a detached shell that first waits for THIS process to exit, then
        // reopens the app. `openApplication(createsNewApplicationInstance:)` races the
        // terminate — macOS keeps the still-running instance in front, so the mode never
        // actually changes. Waiting for our PID to die guarantees one clean new instance.
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
    #endif

    @objc private func openShelf() {
        coordinator.toggleShelf()
    }

    @objc private func createItem() {
        coordinator.newItem()
    }

    @objc private func pasteMenuItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        coordinator.paste(item)
    }

    @objc private func togglePause() {
        coordinator.togglePause()
    }

    @objc private func exportHistory() {
        coordinator.exportHistory()
    }

    @objc private func importHistory() {
        coordinator.importHistory()
    }

    /// Shared by the status-menu item and CopyApp's replacement for SwiftUI's default
    /// ⌘, command, so both routes reach the real AppKit-owned settings window.
    func openSettingsFromCommand() {
        coordinator.openSettings()
    }

    @objc private func openSettings() {
        openSettingsFromCommand()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc private func togglePasteStack() {
        coordinator.togglePasteStack()
    }

    @objc private func clearHistory() {
        coordinator.confirmAndClearHistory()
    }
}

// MARK: - Quick Look panel control

/// `AppDelegate` is always reachable via `NSApp.delegate`, so it's a reliable place to
/// implement Quick Look's responder-chain "who controls the panel" trio — these three
/// methods are an informal `NSObject` category (not a protocol Swift enforces), called
/// by AppKit whenever `QLPreviewPanel` re-resolves its controller (e.g. as it becomes
/// key). `QuickLookController.preview(_:)` already sets `dataSource`/`delegate`
/// directly before showing the panel; this extension just keeps that assignment
/// correct if AppKit re-runs its own controller search afterward.
extension AppDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        QuickLookController.shared.hasContent
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        QuickLookController.shared.clear()
    }
}
