import CopyCore
import SwiftUI

/// Root content of the Settings window (hosted by `SettingsWindowController`): a
/// System-Settings-style sidebar (`NavigationSplitView`) of five sections, each backed by
/// the shared `SettingsStore` (see `AppCoordinator.settings`).
///
/// The window is tinted electric-blue (`Tokens.electricBlue`) so the sidebar selection and
/// all controls read as one brand accent, but it otherwise stays native: it follows the
/// system appearance and each pane's controls sit in a grouped `Form`. That last choice is
/// deliberate and unchanged from the tabbed version — unlike the shelf/paste stack/sheets,
/// Settings keeps its content on the opaque grouped-form background rather than glass, the
/// same way Apple's System Settings reserves glass for chrome (the sidebar) and not the
/// settings content itself.
struct SettingsView: View {
    let settings: SettingsStore
    let store: ItemStore
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: 8) {
                        SettingsSectionTile(systemImage: section.systemImage, color: section.tileColor)
                        Text(section.title)
                    }
                    .padding(.vertical, 2)
                    .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 178, ideal: 196, max: 230)
        } detail: {
            detail(for: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .tint(Tokens.electricBlue)
        .frame(minWidth: 640, minHeight: 460)
    }

    /// About leads with its own centered identity block; the other four panes get the
    /// standard hero above their grouped `Form`.
    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            pane(.general) { GeneralSettings(settings: settings) }
        case .shortcuts:
            pane(.shortcuts) { ShortcutsSettings(settings: settings) }
        case .history:
            pane(.history) { HistorySettings(settings: settings, store: store) }
        case .privacy:
            pane(.privacy) { PrivacySettings(settings: settings) }
        case .permissions:
            pane(.permissions) { PermissionsSettings(settings: settings) }
        case .about:
            AboutSettings(settings: settings)
        }
    }

    private func pane<Content: View>(_ section: SettingsSection, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            SettingsPaneHeader(section: section)
            content()
        }
    }
}
