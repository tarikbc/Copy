import SwiftUI
import AppKit
import CopyCore
import UniformTypeIdentifiers

enum Tokens {
    static let cardWidth: CGFloat = 184
    static let cardHeight: CGFloat = 244
    static let cardGap: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let shelfPadding: CGFloat = 20

    /// Compact shelf mode (`SettingsStore.compactShelf`): narrower/shorter cards and a
    /// tighter grid, so more items fit at a glance. `cardWidth(compact:)`/`cardHeight(compact:)`
    /// etc. below are what call sites should read rather than branching on the raw
    /// constants directly.
    static let compactCardWidth: CGFloat = 132
    static let compactCardHeight: CGFloat = 168
    static let compactCardGap: CGFloat = 8
    static let compactShelfPadding: CGFloat = 14

    static func cardWidth(compact: Bool) -> CGFloat { compact ? compactCardWidth : cardWidth }
    static func cardHeight(compact: Bool) -> CGFloat { compact ? compactCardHeight : cardHeight }
    static func cardGap(compact: Bool) -> CGFloat { compact ? compactCardGap : cardGap }
    static func shelfPadding(compact: Bool) -> CGFloat { compact ? compactShelfPadding : shelfPadding }

    /// Regular clipboard prose uses the native system face; code keeps monospace.
    static let cardBody = Font.system(size: 12)
    static let bodyMono = Font.system(size: 11, design: .monospaced)
    static let caption = Font.system(size: 10, weight: .medium)
    static let cardTitle = Font.system(size: 11, weight: .semibold)
    /// Secondary-but-prominent label style: `ItemCardView`'s custom-title row and its
    /// link-card host name. One step up from `cardTitle`, shared so both read at the
    /// same size/weight instead of each carrying its own literal.
    static let cardSubtitle = Font.system(size: 12, weight: .semibold)

    /// The marketing "electric blue" accent, used as the fixed tint in the pro-dark
    /// shelf so the app matches its own brand look regardless of the system accent.
    static let electricBlue = Color(red: 0.298, green: 0.616, blue: 1.0) // #4C9DFF

    static func color(fromHex hex: String) -> Color {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else {
            return .gray
        }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Converts a SwiftUI `Color` back to a "#RRGGBB" hex string, matching
    /// `PasteboardReading.colorHex()`'s sRGB formatting so a re-copied color round-trips
    /// through the same representation a captured color would.
    static func hex(from color: Color) -> String {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return String(format: "#%02X%02X%02X",
                      Int(round(srgb.redComponent * 255)),
                      Int(round(srgb.greenComponent * 255)),
                      Int(round(srgb.blueComponent * 255)))
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Resolves the icon to show for a `.file` item from its first captured path's
    /// extension. Multi-file drops store one path per line in `plainText`; only the
    /// first matters here since the file glyph is otherwise identical across the
    /// batch. Shared between `ItemCardView`'s card icon and `PreviewPane`'s larger one.
    static func fileType(for item: ClipItem) -> UTType {
        let ext = (item.plainText?.components(separatedBy: "\n").first as NSString?)?.pathExtension ?? ""
        return UTType(filenameExtension: ext) ?? .data
    }
}
