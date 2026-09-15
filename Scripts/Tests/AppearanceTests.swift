import AppKit
import Foundation

@main
struct AppearanceTests {
    @MainActor static func main() {
        for legacy in [false, true] {
            let name = "CopyTests.Appearance.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(legacy, forKey: SettingsStore.shelfProDarkKey)
            let settings = SettingsStore(defaults: defaults)
            precondition(settings.shelfTheme == (legacy ? .dark : .system))
            var callbacks = 0
            settings.onShelfThemeChange = { _ in callbacks += 1 }
            let current = settings.shelfTheme
            settings.shelfTheme = current
            precondition(callbacks == 0)
            for theme in ShelfTheme.allCases {
                settings.shelfTheme = theme
                precondition(SettingsStore(defaults: defaults).shelfTheme == theme)
            }
            defaults.set("light", forKey: SettingsStore.shelfThemeKey)
            precondition(SettingsStore(defaults: defaults).shelfTheme == .light)
            defaults.set("invalid", forKey: SettingsStore.shelfThemeKey)
            precondition(SettingsStore(defaults: defaults).shelfTheme == (legacy ? .dark : .system))
        }
        precondition(ShelfTheme.system.appearance == nil)
        precondition(ShelfTheme.light.appearance?.name == .aqua)
        precondition(ShelfTheme.dark.appearance?.name == .darkAqua)
        print("PASS: legacy migration, saved choice, round-trip, callbacks and appearance mapping")
    }
}
