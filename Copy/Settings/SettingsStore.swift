import AppKit
import Foundation
import Observation

/// Optional feedback played after Copy successfully records a clipboard change. Every
/// case but `off` is one of the fourteen sounds macOS ships in `/System/Library/Sounds`,
/// listed in the order the system itself lists them, and the picker shows each under the
/// name the system uses, so what a screener reads here is what they would read in Sound
/// settings. Raw values are persisted in UserDefaults, so keep them stable across
/// releases.
enum CopySound: String, CaseIterable, Identifiable {
    case off
    case basso, blow, bottle, frog, funk, glass, hero
    case morse, ping, pop, purr, sosumi, submarine, tink

    var id: Self { self }

    /// The sound's file name under `/System/Library/Sounds`. Capitalising the raw value
    /// is the whole mapping, because every sound macOS ships is a single capitalised
    /// word. A name that ever stops resolving simply plays nothing (see `CopySoundPlayer`).
    var systemSoundName: NSSound.Name? {
        guard self != .off else { return nil }
        return NSSound.Name(rawValue.capitalized)
    }

    var title: String {
        systemSoundName ?? "Off"
    }
}

/// How long unfavorited, unpinned history items are kept before pruning.
enum RetentionPeriod: String, CaseIterable {
    case unlimited
    case day
    case week
    case month
    case threeMonths

    /// The earliest `lastUsedAt` to keep; `nil` means keep everything.
    var cutoff: Date? {
        let now = Date()
        switch self {
        case .unlimited:
            return nil
        case .day:
            return Calendar.current.date(byAdding: .day, value: -1, to: now)
        case .week:
            return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .month:
            return Calendar.current.date(byAdding: .month, value: -1, to: now)
        case .threeMonths:
            return Calendar.current.date(byAdding: .month, value: -3, to: now)
        }
    }

    var title: String {
        switch self {
        case .unlimited: return "Unlimited"
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .threeMonths: return "3 Months"
        }
    }

    /// Shortest-to-longest order for the History pane's `StepSlider`, ending in Unlimited
    /// (the default) at the far right. The `enum`'s own declaration order leads with
    /// `.unlimited`, which is the right default but the wrong slider position.
    static let sliderOrder: [RetentionPeriod] = [.day, .week, .month, .threeMonths, .unlimited]
}

/// UserDefaults-backed app settings. Mutating `excludedBundleIDs` (directly or via
/// `addExcludedApp`/`removeExcludedApp`) fires `onRulesChange` so the coordinator can
/// push a fresh `RulesEngine` into the clipboard monitor.
@MainActor
@Observable
final class SettingsStore {
    static let retentionKey = "retentionPeriod"
    static let fetchLinkPreviewsKey = "fetchLinkPreviews"
    static let recognizeImageTextKey = "recognizeImageText"
    static let excludedBundleIDsKey = "excludedBundleIDs"
    static let hideDuringScreenSharingKey = "hideDuringScreenSharing"
    static let favoritesEnabledKey = "favoritesEnabled"
    static let compactShelfKey = "compactShelf"
    static let shelfProDarkKey = "shelfProDark"
    static let hideMenuBarIconKey = "hideMenuBarIcon"
    static let doubleClickToPasteKey = "doubleClickToPaste"
    static let copySoundKey = "copySound"

    var retention: RetentionPeriod {
        didSet {
            guard retention != oldValue else { return }
            defaults.set(retention.rawValue, forKey: Self.retentionKey)
        }
    }

    var fetchLinkPreviews: Bool {
        didSet {
            guard fetchLinkPreviews != oldValue else { return }
            defaults.set(fetchLinkPreviews, forKey: Self.fetchLinkPreviewsKey)
        }
    }

    var recognizeImageText: Bool {
        didSet {
            guard recognizeImageText != oldValue else { return }
            defaults.set(recognizeImageText, forKey: Self.recognizeImageTextKey)
        }
    }

    var excludedBundleIDs: [String] {
        didSet {
            guard excludedBundleIDs != oldValue else { return }
            persistExcludedBundleIDs()
            onRulesChange?(Set(excludedBundleIDs))
        }
    }

    /// When true, the shelf panel and Paste Stack palette set `NSWindowSharingType.none`
    /// so they're excluded from screen recordings/captures/shares (see
    /// `ShelfPanelController.setHideDuringScreenSharing`/`PasteStackController`'s
    /// equivalent). Defaults to false: Copy is visible in screenshots and recordings
    /// out of the box (so people can capture and share it), and hiding is opt-in.
    var hideDuringScreenSharing: Bool {
        didSet {
            guard hideDuringScreenSharing != oldValue else { return }
            defaults.set(hideDuringScreenSharing, forKey: Self.hideDuringScreenSharingKey)
            onHideDuringScreenSharingChange?(hideDuringScreenSharing)
        }
    }

    /// Narrower/shorter cards and a shorter shelf panel, so more items fit at a glance.
    /// `ShelfRootView`/`ItemCardView` read this live (via `ShelfViewModel.settings`,
    /// since both are `@Observable`), and `onCompactShelfChange` pushes it to
    /// `ShelfPanelController` so the panel's own frame height adapts, mirroring
    /// `hideDuringScreenSharing`'s wiring above.
    var compactShelf: Bool {
        didSet {
            guard compactShelf != oldValue else { return }
            defaults.set(compactShelf, forKey: Self.compactShelfKey)
            onCompactShelfChange?(compactShelf)
        }
    }

    /// Hides favorites presentation without deleting saved marks or retention protection.
    var favoritesEnabled: Bool {
        didSet {
            guard favoritesEnabled != oldValue else { return }
            defaults.set(favoritesEnabled, forKey: Self.favoritesEnabledKey)
            onFavoritesEnabledChange?(favoritesEnabled)
        }
    }
    @ObservationIgnored var onFavoritesEnabledChange: ((Bool) -> Void)?

    /// A fixed "pro dark" look for the shelf and paste stack: a forced dark appearance
    /// plus an electric-blue accent, regardless of the system appearance or accent color
    /// (so the app matches its own marketing look). Off by default, so the shelf follows
    /// the system otherwise. `onShelfProDarkChange` pushes it to the panel controllers
    /// (which set the window appearance live); `ShelfRootView` reads it via
    /// `ShelfViewModel.settings` to apply the tint.
    var shelfProDark: Bool {
        didSet {
            guard shelfProDark != oldValue else { return }
            defaults.set(shelfProDark, forKey: Self.shelfProDarkKey)
            onShelfProDarkChange?(shelfProDark)
        }
    }

    /// When true, `AppDelegate` removes the `NSStatusItem` so Copy runs with no menu
    /// bar icon at all, relying on the shelf's own drawer menu (and the shelf summon
    /// hotkey) instead. Defaults to false: the icon is shown out of the box, and
    /// going menu-bar-free is opt-in. `AppDelegate` applies an anti-stranding guard on
    /// top of this value — it refuses to actually hide the icon if the shelf summon
    /// hotkey is unset — so this property alone doesn't guarantee the icon is hidden.
    var hideMenuBarIcon: Bool {
        didSet {
            guard hideMenuBarIcon != oldValue else { return }
            defaults.set(hideMenuBarIcon, forKey: Self.hideMenuBarIconKey)
            onHideMenuBarIconChange?(hideMenuBarIcon)
        }
    }

    /// When true, a plain click on a shelf card only selects it (no paste) — pasting
    /// takes a double-click or ⏎. Defaults to true: this is the safer default, since a
    /// stray single click can no longer paste a card into whatever app is frontmost.
    /// Read live at click time via `ShelfViewModel.settings` (both `@Observable`), so
    /// there's no change-hook to wire — unlike `compactShelf`/`hideMenuBarIcon`, nothing
    /// outside SwiftUI needs to react to this changing.
    var doubleClickToPaste: Bool {
        didSet {
            guard doubleClickToPaste != oldValue else { return }
            defaults.set(doubleClickToPaste, forKey: Self.doubleClickToPasteKey)
        }
    }

    /// Sound feedback for successful clipboard captures. Off is the intentional
    /// default so installing or updating Copy never adds noise without consent.
    var copySound: CopySound {
        didSet {
            guard copySound != oldValue else { return }
            defaults.set(copySound.rawValue, forKey: Self.copySoundKey)
        }
    }

    @ObservationIgnored var onRulesChange: ((Set<String>) -> Void)?
    /// Fired by the About pane's "Check for Updates…" button. Bridged to Sparkle's
    /// `updaterController` in `AppDelegate` (which owns it), so this store — and the
    /// SwiftUI settings views — never depend on Sparkle directly.
    @ObservationIgnored var onCheckForUpdates: (() -> Void)?
    /// Fired by the About pane's "View Onboarding Again" button. Wired to
    /// `AppCoordinator.showOnboarding()`, which re-presents the welcome flow from step 0.
    @ObservationIgnored var onShowOnboarding: (() -> Void)?
    @ObservationIgnored var onHideDuringScreenSharingChange: ((Bool) -> Void)?
    @ObservationIgnored var onCompactShelfChange: ((Bool) -> Void)?
    @ObservationIgnored var onShelfProDarkChange: ((Bool) -> Void)?
    @ObservationIgnored var onHideMenuBarIconChange: ((Bool) -> Void)?
    /// Not backed by a stored property here — the shelf summon hotkey itself lives in
    /// `KeyboardShortcuts`' own storage (see `KeyboardShortcuts.Name.toggleShelf`), not
    /// in `SettingsStore`. This is a pure passthrough notification: `GeneralSettings`
    /// calls it from the `.toggleShelf` `KeyboardShortcuts.Recorder`'s `onChange`, and
    /// `AppDelegate` uses it as the third trigger to re-run its `hideMenuBarIcon`
    /// anti-stranding guard (`applyHideMenuBarIconSetting`) — that guard must re-check
    /// even when `hideMenuBarIcon` itself didn't change, since clearing the hotkey while
    /// already hidden is exactly the case it exists to catch.
    @ObservationIgnored var onShelfHotkeyChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.retentionKey), let period = RetentionPeriod(rawValue: raw) {
            retention = period
        } else {
            retention = .unlimited
        }
        fetchLinkPreviews = (defaults.object(forKey: Self.fetchLinkPreviewsKey) as? Bool) ?? true
        recognizeImageText = (defaults.object(forKey: Self.recognizeImageTextKey) as? Bool) ?? true
        hideDuringScreenSharing = (defaults.object(forKey: Self.hideDuringScreenSharingKey) as? Bool) ?? false
        favoritesEnabled = (defaults.object(forKey: Self.favoritesEnabledKey) as? Bool) ?? true
        compactShelf = (defaults.object(forKey: Self.compactShelfKey) as? Bool) ?? false
        shelfProDark = (defaults.object(forKey: Self.shelfProDarkKey) as? Bool) ?? false
        hideMenuBarIcon = (defaults.object(forKey: Self.hideMenuBarIconKey) as? Bool) ?? false
        doubleClickToPaste = (defaults.object(forKey: Self.doubleClickToPasteKey) as? Bool) ?? true
        copySound = defaults.string(forKey: Self.copySoundKey)
            .flatMap(CopySound.init(rawValue:)) ?? .off
        if let data = defaults.data(forKey: Self.excludedBundleIDsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            excludedBundleIDs = decoded.sorted()
        } else {
            excludedBundleIDs = []
        }
    }

    func addExcludedApp(bundleID: String) {
        guard !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs = (excludedBundleIDs + [bundleID]).sorted()
    }

    func removeExcludedApp(bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    private func persistExcludedBundleIDs() {
        guard let data = try? JSONEncoder().encode(excludedBundleIDs) else { return }
        defaults.set(data, forKey: Self.excludedBundleIDsKey)
    }
}
