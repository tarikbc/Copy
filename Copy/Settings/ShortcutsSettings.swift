import KeyboardShortcuts
import SwiftUI

/// The hotkey recorders, split out of General into their own pane. The `.toggleShelf`
/// recorder still fires `onShelfHotkeyChange` so `AppDelegate`'s anti-stranding guard
/// re-runs when the shelf summon hotkey changes (see `SettingsStore.onShelfHotkeyChange`);
/// the General pane re-reads whether that shortcut is set in its own `onAppear` to gate the
/// "Hide the Menu Bar Icon" toggle.
struct ShortcutsSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open Copy:", name: .toggleShelf) { _ in
                    settings.onShelfHotkeyChange?()
                }
                KeyboardShortcuts.Recorder(settings.shelfMode == .full ? "Open Mini Shelf:" : "Open Full Shelf:",
                                           name: .toggleAlternateShelf)
                KeyboardShortcuts.Recorder("Paste Stack:", name: .togglePasteStack)
                KeyboardShortcuts.Recorder("Quick Paste Latest:", name: .quickPasteLatest)
                KeyboardShortcuts.Recorder("Next Pinboard:", name: .nextPinboard)
            } footer: {
                Text("Quick Paste Latest pastes your most recent item into the current app without opening Copy. While the shelf is open, hold Option and press a number to paste that card.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
