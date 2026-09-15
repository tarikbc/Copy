import Foundation

/// The type facet, mirroring `ShelfScope`'s categories (Text folds in rich text). Kept in
/// CopyCore (like `ShelfScope`) so its `kinds` mapping and the suggestion ranking are
/// unit-testable; the SF Symbol names are consumed by the app's token field.
public enum SearchType: String, CaseIterable, Equatable, Sendable {
    case text, links, images, files, colors

    public var label: String {
        switch self {
        case .text: return "Text"
        case .links: return "Link"
        case .images: return "Image"
        case .files: return "File"
        case .colors: return "Color"
        }
    }

    public var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        case .colors: return "paintpalette"
        }
    }

    public var kinds: Set<ItemKind> {
        switch self {
        case .text: return [.text, .richText]
        case .links: return [.link]
        case .images: return [.image]
        case .files: return [.file]
        case .colors: return [.color]
        }
    }
}

/// The time facet. Stores the case, not a resolved interval, so a `Last 7 days` token stays
/// relative — the interval is computed fresh at each `SearchQuery.toFilter`.
public enum SearchDate: String, CaseIterable, Equatable, Sendable {
    case today, yesterday, last7, last30, last90

    public var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7: return "Last week"
        case .last30: return "Last month"
        case .last90: return "Last 3 months"
        }
    }

    public var systemImage: String { "calendar" }

    /// Half-open calendar-day range `[start, startOfTomorrow)` matched against `lastUsedAt`.
    public func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        func daysBack(_ n: Int) -> Date {
            calendar.date(byAdding: .day, value: -n, to: startOfToday) ?? startOfToday
        }
        switch self {
        case .today: return DateInterval(start: startOfToday, end: startOfTomorrow)
        case .yesterday: return DateInterval(start: daysBack(1), end: startOfToday)
        case .last7: return DateInterval(start: daysBack(6), end: startOfTomorrow)
        case .last30: return DateInterval(start: daysBack(29), end: startOfTomorrow)
        case .last90: return DateInterval(start: daysBack(89), end: startOfTomorrow)
        }
    }
}

/// A committed facet pill in the search field.
public enum SearchToken: Equatable, Identifiable, Sendable {
    case app(bundleID: String, name: String)
    case type(SearchType)
    case date(SearchDate)
    case favorites
    case pinboard(id: Int64, name: String)

    public var id: String {
        switch self {
        case .app(let bundleID, _): return "app:\(bundleID)"
        case .type(let type): return "type:\(type.rawValue)"
        case .date(let date): return "date:\(date.rawValue)"
        case .favorites: return "favorites"
        case .pinboard(let id, _): return "pinboard:\(id)"
        }
    }

    public var label: String {
        switch self {
        case .app(_, let name): return name
        case .type(let type): return type.label
        case .date(let date): return date.label
        case .favorites: return "Favorites"
        case .pinboard(_, let name): return name
        }
    }

    /// `nil` for apps — the token field renders the app icon instead of an SF Symbol.
    public var systemImage: String? {
        switch self {
        case .app: return nil
        case .type(let type): return type.systemImage
        case .date(let date): return date.systemImage
        case .favorites: return "star.fill"
        case .pinboard: return "pin.fill"
        }
    }

    public var appBundleID: String? {
        if case .app(let bundleID, _) = self { return bundleID }
        return nil
    }
}

/// The full search: committed facet tokens plus trailing free text (FTS over
/// plainText/title/OCR). Combined into a `SearchFilter` for the store.
public struct SearchQuery: Equatable, Sendable {
    public var tokens: [SearchToken]
    public var text: String

    public init(tokens: [SearchToken] = [], text: String = "") {
        self.tokens = tokens
        self.text = text
    }

    public var isEmpty: Bool {
        tokens.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func toFilter(now: Date = Date(), calendar: Calendar = .current) -> SearchFilter {
        var filter = SearchFilter(text: text)
        var kinds: Set<ItemKind> = []
        var pinboardIDs: Set<Int64> = []
        for token in tokens {
            switch token {
            case .app(let bundleID, _): filter.appBundleID = bundleID
            case .type(let type):
                kinds.formUnion(type.kinds)
                if type == .images { filter.includesImageFiles = true }
            case .date(let date): filter.dateRange = date.interval(now: now, calendar: calendar)
            case .favorites: filter.favoritesOnly = true
            case .pinboard(let id, _): pinboardIDs.insert(id)
            }
        }
        filter.kinds = kinds
        filter.pinboardIDs = pinboardIDs
        return filter
    }

    /// Adds a token. App and Date are single-valued (a new one replaces the old); the rest
    /// are deduplicated.
    public mutating func add(_ token: SearchToken) {
        switch token {
        case .app:
            tokens.removeAll { if case .app = $0 { return true } else { return false } }
        case .date:
            tokens.removeAll { if case .date = $0 { return true } else { return false } }
        default:
            guard !tokens.contains(token) else { return }
        }
        tokens.append(token)
    }

    public mutating func removeLast() {
        if !tokens.isEmpty { tokens.removeLast() }
    }

    public mutating func remove(_ token: SearchToken) {
        tokens.removeAll { $0 == token }
    }
}

/// A ranked suggestion offered while typing. Same cases as `SearchToken` plus a `priority`
/// for ordering.
public enum Suggestion: Equatable, Identifiable, Sendable {
    case app(bundleID: String, name: String)
    case type(SearchType)
    case date(SearchDate)
    case favorites
    case pinboard(id: Int64, name: String)

    public var token: SearchToken {
        switch self {
        case .app(let bundleID, let name): return .app(bundleID: bundleID, name: name)
        case .type(let type): return .type(type)
        case .date(let date): return .date(date)
        case .favorites: return .favorites
        case .pinboard(let id, let name): return .pinboard(id: id, name: name)
        }
    }

    public var id: String { token.id }
    public var label: String { token.label }
    public var systemImage: String? { token.systemImage }
    public var appBundleID: String? { token.appBundleID }

    /// Category order in the dropdown: type, favorites, pinboard, app, date.
    var priority: Int {
        switch self {
        case .type: return 0
        case .favorites: return 1
        case .pinboard: return 2
        case .app: return 3
        case .date: return 4
        }
    }
}

/// Ranked facet suggestions for the current trailing text. Case-insensitive prefix match
/// across type/favorites/pinboard/app/date, excluding facets already satisfied by `query`
/// (single-valued app/date once set; any already-present token). Empty prefix → no
/// suggestions. Stable-sorted by category priority, then by input order (apps stay in the
/// frequency order `distinctApps` returns).
public func searchSuggestions(prefix rawPrefix: String,
                              apps: [AppUsage],
                              pinboards: [Pinboard],
                              query: SearchQuery,
                              limit: Int = 6, includeFavorites: Bool = true) -> [Suggestion] {
    let prefix = rawPrefix.trimmingCharacters(in: .whitespaces).lowercased()
    guard !prefix.isEmpty else { return [] }

    let hasApp = query.tokens.contains { if case .app = $0 { return true } else { return false } }
    let hasDate = query.tokens.contains { if case .date = $0 { return true } else { return false } }
    let hasFavorites = query.tokens.contains(.favorites)

    var out: [Suggestion] = []

    for type in SearchType.allCases where matchesPrefix(type.label, prefix) && !query.tokens.contains(.type(type)) {
        out.append(.type(type))
    }
    if includeFavorites && matchesPrefix("Favorites", prefix) && !hasFavorites {
        out.append(.favorites)
    }
    for pinboard in pinboards {
        guard let id = pinboard.id, matchesPrefix(pinboard.name, prefix),
              !query.tokens.contains(.pinboard(id: id, name: pinboard.name)) else { continue }
        out.append(.pinboard(id: id, name: pinboard.name))
    }
    if !hasApp {
        for app in apps where matchesPrefix(app.name, prefix) {
            out.append(.app(bundleID: app.bundleID, name: app.name))
        }
    }
    if !hasDate {
        for date in SearchDate.allCases where matchesPrefix(date.label, prefix) {
            out.append(.date(date))
        }
    }

    let ranked = out.enumerated()
        .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
        .map(\.element)
    return Array(ranked.prefix(limit))
}

/// Case-insensitive prefix match on the whole label OR on any of its words, so "week" finds
/// "Last week" and "safari" finds "Safari" — not just matches anchored at the very start.
/// The label is cleaned first, so an invisible leading mark (e.g. the U+200E macOS prepends
/// to "WhatsApp") doesn't break the match.
private func matchesPrefix(_ label: String, _ prefix: String) -> Bool {
    let lowered = cleanedName(label).lowercased()
    if lowered.hasPrefix(prefix) { return true }
    return lowered.split(separator: " ").contains { $0.hasPrefix(prefix) }
}

/// Strips Unicode format characters (macOS prepends the U+200E left-to-right mark to some
/// app names, e.g. WhatsApp) and trims whitespace, so names match and display cleanly.
func cleanedName(_ text: String) -> String {
    let scalars = text.unicodeScalars.filter { $0.properties.generalCategory != .format }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
}
