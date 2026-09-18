import Foundation

@main
struct FavoritesSettingsTests {
    @MainActor static func main() {
        let name = "CopyTests.Favorites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        precondition(settings.favoritesEnabled)
        var events: [Bool] = []
        settings.onFavoritesEnabledChange = { events.append($0) }
        settings.favoritesEnabled = false
        settings.favoritesEnabled = false
        precondition(events == [false])
        precondition(!SettingsStore(defaults: defaults).favoritesEnabled)
        settings.favoritesEnabled = true
        precondition(events == [false, true])
        precondition(SettingsStore(defaults: defaults).favoritesEnabled)
        print("PASS: favorites default, persistence and live callback")
    }
}
