import Foundation

public enum TextSeparator: String, CaseIterable, Sendable {
    case comma, newline, semicolon, tab, space, custom, regex

    public var title: String {
        switch self {
        case .comma: return "Comma"
        case .newline: return "New line"
        case .semicolon: return "Semicolon"
        case .tab: return "Tab"
        case .space: return "Space"
        case .custom: return "Custom"
        case .regex: return "Regex"
        }
    }
}

public struct TextSplitResult: Sendable {
    public let entries: [String]
    public let error: String?
}

public struct TextSplitSuggestion: Equatable, Sendable {
    public let separator: TextSeparator
    public let pattern: String

    /// Reject malformed or ineffective model output before presenting a suggestion.
    public static func validated(separator name: String, pattern: String, text: String) -> Self? {
        guard let separator = TextSeparator(rawValue: name), separator != .custom else { return nil }
        let pattern = separator == .regex ? pattern : ""
        let result = TextSplitter.result(text, separator: separator, pattern: pattern)
        guard result.error == nil, result.entries.count > 1 else { return nil }
        return Self(separator: separator, pattern: pattern)
    }
}

public enum TextSplitter {
    /// Suggestions select boundaries; they never generate or rewrite the user's text.
    public static func split(_ text: String, separator: TextSeparator,
                             custom: String = "", pattern: String = "", removeDuplicates: Bool = false) -> [String] {
        result(text, separator: separator, custom: custom, pattern: pattern,
               removeDuplicates: removeDuplicates).entries
    }

    public static func result(_ text: String, separator: TextSeparator,
                              custom: String = "", pattern: String = "", removeDuplicates: Bool = false) -> TextSplitResult {
        let parts: [String]
        switch separator {
        case .newline: parts = text.components(separatedBy: .newlines)
        case .comma: parts = text.components(separatedBy: ",")
        case .semicolon: parts = text.components(separatedBy: ";")
        case .tab: parts = text.components(separatedBy: "\t")
        case .space: parts = text.components(separatedBy: " ")
        case .custom:
            guard !custom.isEmpty else { return TextSplitResult(entries: [], error: nil) }
            parts = text.components(separatedBy: custom)
        case .regex:
            let result = regexParts(text, pattern: pattern)
            guard result.error == nil else { return result }
            parts = result.entries
        }
        var seen = Set<String>()
        let entries = parts.compactMap { part -> String? in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !removeDuplicates || seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        return TextSplitResult(entries: entries, error: nil)
    }

    private static func regexParts(_ text: String, pattern: String) -> TextSplitResult {
        guard !pattern.isEmpty else { return TextSplitResult(entries: [], error: "Enter a regex pattern.") }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return TextSplitResult(entries: [], error: "Invalid regex. Check the pattern.")
        }
        let source = text as NSString
        var parts: [String] = []
        var cursor = 0
        var error: String?
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        // Progress callbacks also run during backtracking, so a slow pattern can stop.
        regex.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                               range: NSRange(location: 0, length: source.length)) { match, flags, stop in
            if ProcessInfo.processInfo.systemUptime > deadline {
                error = "This regex takes too long. Use a simpler pattern."
                stop.pointee = true
                return
            }
            if flags.contains(.internalError) {
                error = "This regex could not run. Use a simpler pattern."
                stop.pointee = true
                return
            }
            guard let match else { return }
            parts.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = NSMaxRange(match.range)
        }
        if let error { return TextSplitResult(entries: [], error: error) }
        parts.append(source.substring(from: cursor))
        return TextSplitResult(entries: parts, error: nil)
    }

    /// A fast fallback that remains available without Apple Intelligence.
    public static func suggestedSeparator(for text: String) -> TextSeparator? {
        let structured: [TextSeparator] = [.newline, .tab, .semicolon, .comma]
        let candidates = structured.map { ($0, split(text, separator: $0).count) }
        if let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 1 { return best.0 }
        return split(text, separator: .space).count > 1 ? .space : nil
    }
}
