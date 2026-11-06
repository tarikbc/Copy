import SwiftUI

/// The five panes of the Settings window, in sidebar order. Single source of truth for the
/// sidebar rows and each pane's hero header (`SettingsPaneHeader`), so a section's icon,
/// color, and copy are defined once.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcuts
    case history
    case privacy
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .history: return "History"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .history: return "clock"
        case .privacy: return "hand.raised"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    /// The rounded-square tile color, in the System Settings idiom. About takes the brand
    /// accent; the rest use distinct system hues that don't clash with it.
    var tileColor: Color {
        switch self {
        case .general: return .gray
        case .shortcuts: return .blue
        case .history: return .orange
        case .privacy: return .red
        case .permissions: return .purple
        case .about: return Tokens.electricBlue
        }
    }

    /// One-line description shown under the title in the pane hero.
    var subtitle: String {
        switch self {
        case .general: return "Appearance, behavior, and startup."
        case .shortcuts: return "Set the keys that summon Copy and paste for you."
        case .history: return "How long items are kept and what Copy enriches."
        case .privacy: return "Keep sensitive apps and shared screens out of history."
        case .permissions: return "Manage apps allowed to send items to Paste Stack."
        case .about: return "Version, updates, and project links."
        }
    }
}
