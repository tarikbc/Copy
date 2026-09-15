import Foundation

// Run by compiling this file together with Copy/Settings/SettingsStore.swift.
@main
struct PrivateAppDefaultsTests {
    @MainActor static func main() throws {
        func profile(_ check: (UserDefaults) throws -> Void) rethrows {
            let name = "CopyTests.PrivateDefaults.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try check(defaults)
        }
        profile { defaults in
            let settings = SettingsStore(defaults: defaults)
            precondition(settings.excludedBundleIDs == ["com.apple.Passwords", "com.apple.keychainaccess"])
            precondition(SettingsStore(defaults: defaults).excludedBundleIDs == settings.excludedBundleIDs)
            settings.removeExcludedApp(bundleID: "com.apple.Passwords")
            settings.removeExcludedApp(bundleID: "com.apple.keychainaccess")
            precondition(SettingsStore(defaults: defaults).excludedBundleIDs.isEmpty)
        }
        try profile { defaults in
            defaults.set(try JSONEncoder().encode([String]()), forKey: SettingsStore.excludedBundleIDsKey)
            precondition(SettingsStore(defaults: defaults).excludedBundleIDs.isEmpty)
        }
        try profile { defaults in
            defaults.set(try JSONEncoder().encode(["example.private"]), forKey: SettingsStore.excludedBundleIDsKey)
            precondition(SettingsStore(defaults: defaults).excludedBundleIDs == ["example.private"])
        }
        profile { defaults in
            defaults.set(true, forKey: "hasOnboarded")
            precondition(SettingsStore(defaults: defaults).excludedBundleIDs.isEmpty)
        }
        profile { defaults in
            defaults.set(Data("invalid".utf8), forKey: SettingsStore.excludedBundleIDsKey)
            _ = SettingsStore(defaults: defaults)
            precondition(defaults.data(forKey: SettingsStore.excludedBundleIDsKey) == Data("invalid".utf8))
        }
        print("PASS: new, existing, empty, custom, corrupt and persisted exclusion profiles")
    }
}
