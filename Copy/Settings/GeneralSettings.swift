import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Hotkey recorders and the Launch at Login toggle. Launch at Login isn't part of
/// `SettingsStore` (it's not a UserDefaults value, it's the `SMAppService` login-item
/// registration), so this view owns its own local state and re-reads the service's
/// actual status after every attempted change rather than trusting the toggle's intent.
struct GeneralSettings: View {
    @Bindable var settings: SettingsStore
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginNeedsApproval = false
    @State private var launchAtLoginError: String?
    /// Mirrors whether `.toggleShelf` currently has a shortcut, for this view's own
    /// disabled/footer state. Tracked in `@State` (updated by the recorder's `onChange`
    /// below and refreshed `onAppear`) rather than read fresh on every body evaluation,
    /// since nothing else in this view is `@Observable`-tracked to that shortcut —
    /// without this, clearing the hotkey wouldn't visibly re-enable/disable anything
    /// here until some unrelated state change happened to force a redraw.
    @State private var shelfHotkeySet = true

    var body: some View {
        Form {
            Section {
                Picker("Shelf Size", selection: $settings.compactShelf) {
                    Text("Standard").tag(false)
                    Text("Compact").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Compact shows smaller cards so more fit in the shelf at once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Shelf Style", selection: $settings.floatingShelf) {
                    Text("Edge Attached").tag(false)
                    Text("Floating").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Floating adds space around the shelf and rounds every corner.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Always Use Dark Shelf", isOn: $settings.shelfProDark)
            } footer: {
                Text("Keeps the shelf and Paste Stack dark with a blue accent, even in Light Mode. Off by default, so they follow your system appearance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Clicking a Card", selection: $settings.doubleClickToPaste) {
                    Text("Selects").tag(true)
                    Text("Pastes").tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.doubleClickToPaste
                     ? "A single click selects a card. Double-click it or press Return to paste."
                     : "A single click selects and immediately pastes a card.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Copy Sound")
                    Spacer()
                    Picker("Copy Sound", selection: $settings.copySound) {
                        ForEach(CopySound.allCases) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                .onChange(of: settings.copySound) { _, sound in
                    CopySoundPlayer.shared.play(sound)
                }
            } footer: {
                Text("Plays after Copy captures a new clipboard item.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
            } footer: {
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if launchAtLoginNeedsApproval {
                    Text("Waiting for approval in System Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                // Only blocks turning the toggle ON without a hotkey — never blocks
                // turning it OFF, so a user who's already stranded (hotkey cleared
                // while this was on) can always self-rescue by flipping it back off.
                // AppDelegate's guard is still the authoritative check either way.
                Toggle("Hide the Menu Bar Icon", isOn: $settings.hideMenuBarIcon)
                    .disabled(!shelfHotkeySet && !settings.hideMenuBarIcon)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !shelfHotkeySet {
                        Text("Set the Open Copy shortcut above before hiding the menu bar icon.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Copy stays available with the Shift Command V shortcut. You can reach Settings and everything else from the shelf.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLaunchAtLoginStatus()
            shelfHotkeySet = KeyboardShortcuts.getShortcut(for: .toggleShelf) != nil
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { setLaunchAtLogin($0) }
        )
    }

    /// A toggle that reads back purely from `.status == .enabled` leaves the user with
    /// no explanation when macOS accepts `register()` but parks the login item pending
    /// approval in System Settings: the switch would just look off again with no clue
    /// why. `.requiresApproval` counts as "on" here (registration did succeed) with a
    /// footnote distinguishing that state from a plain, unregistered off.
    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't update Launch at Login: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }
}
