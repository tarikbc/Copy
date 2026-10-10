import Foundation

/// Finds secrets in copied text (API keys, tokens, private keys, card numbers) so they can
/// be shown masked. Conservative on purpose: it would rather miss a secret than mask
/// ordinary text, so an unquoted lowercase `api_key=value` is skipped (code looks the same).
public enum SecretDetector {
    public static let maskCharacter: Character = "•"

    public static func containsSecret(_ text: String) -> Bool {
        masked(text) != text
    }

    /// `containsSecret` without the display cache, for scanning a whole history.
    public static func scan(_ text: String) -> Bool {
        computeMasked(text) != text
    }

    /// `text` with the middle of each secret replaced by `maskCharacter`. The length never
    /// changes (characters and UTF-16), so highlight token ranges still line up.
    public static func masked(_ text: String) -> String {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = computeMasked(text)
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    /// The first `count` characters, masked. Scans past the cutoff so a secret it slices
    /// through is still caught.
    public static func maskedPrefix(_ text: String, count: Int) -> String {
        String(masked(String(text.prefix(count + cutoffMargin))).prefix(count))
    }

    // MARK: - Detection

    private enum Style {
        /// Keep a few characters at each end.
        case token
        /// Keep the last four digits.
        case card
        /// Hide everything but line breaks (a private key's body).
        case block
    }

    private struct Rule {
        let regex: NSRegularExpression
        /// The capture group holding the secret; 0 is the whole match.
        let group: Int
        let style: Style
    }

    private static let cutoffMargin = 4_096
    /// Text past this is not scanned.
    private static let scanLimit = 250_000
    private static let maskUnit = maskCharacter.utf16.first!

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 600
        return cache
    }()

    /// Names that mark a `name = value` as a secret.
    private static let secretName = "(?:api[_-]?key|secret|token|passw(?:or)?d)"
    /// No `.`, `(`, `&` or `$`: property accesses, calls, URL separators, variables.
    private static let bareValue = "[A-Za-z0-9_+/=~!@#%^*-]"
    /// Needs a letter and a digit, and must not be a path, variable or URL.
    private static func looksLikeSecret(_ valueClass: String) -> String {
        "(?![/~.$]|https?:)(?=\(valueClass)*[A-Za-z])(?=\(valueClass)*[0-9])"
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, group: Int = 0, style: Style = .token,
                  options: NSRegularExpression.Options = []) -> Rule {
            // Literal patterns: a failure is a typo the tests catch.
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), group: group, style: style)
        }
        let quotedValue = "[\\x21\\x23-\\x26\\x28-\\x7E]"   // printable ASCII except quotes
        return [
            // Provider formats, by prefix.
            rule("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"),                               // AWS access key ID
            rule("\\bgh[pousr]_[A-Za-z0-9]{36,}\\b"),                              // GitHub token
            rule("\\bgithub_pat_[A-Za-z0-9_]{50,}\\b"),                            // GitHub fine-grained token
            rule("\\bsk-(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{20,}"),               // OpenAI, Anthropic
            rule("\\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"),                       // Stripe
            rule("\\bwhsec_[A-Za-z0-9]{24,}"),                                     // Stripe webhook secret
            rule("\\bxox[abprs]-[A-Za-z0-9-]{10,}"),                               // Slack
            rule("\\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"),                     // Google API key
            rule("\\bnpm_[A-Za-z0-9]{36}\\b"),                                     // npm
            rule("\\bSG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}"),               // SendGrid
            rule("\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"), // JWT
            rule("\\bbearer\\s+(?=[A-Za-z0-9._~+/=-]*[0-9])([A-Za-z0-9._~+/=-]{20,})",
                 group: 1, options: [.caseInsensitive]),
            // Private key: hide the body (to the end if unterminated), keep BEGIN/END.
            rule("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----([\\s\\S]*?)(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\\z)",
                 group: 1, style: .block),
            // name = "value"
            rule("\(secretName)[A-Za-z0-9_-]{0,40}[\"']?\\s{0,4}[:=]\\s{0,4}[\"']"
                 + "\(looksLikeSecret(quotedValue))(\(quotedValue){12,})[\"']",
                 group: 1, options: [.caseInsensitive]),
            // NAME=value (.env). Case-sensitive on purpose: lowercase is how code looks.
            rule("(?<![A-Za-z0-9_])[A-Z0-9_]{0,40}(?:API_?KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Z0-9_]{0,40}="
                 + "\(looksLikeSecret(bareValue))(\(bareValue){12,})",
                 group: 1),
            // ?token=value in a URL.
            rule("[?&][A-Za-z0-9_.-]{0,40}(?:\(secretName)|signature)[A-Za-z0-9_-]{0,40}="
                 + "\(looksLikeSecret("[A-Za-z0-9_+/=~%.-]"))([A-Za-z0-9_+/=~%.-]{12,})",
                 group: 1, options: [.caseInsensitive]),
            // 15 or 16 digits, optionally grouped; checked by `isCardNumber`.
            rule("(?<![A-Za-z0-9])(?<![0-9][ -])(?:[0-9][ -]?){14,15}[0-9](?![A-Za-z0-9])(?![ -]?[0-9])",
                 style: .card),
        ]
    }()

    private static func computeMasked(_ text: String) -> String {
        var units = Array(text.utf16)
        let source = text as NSString
        let scanRange = NSRange(location: 0, length: min(source.length, scanLimit))
        var changed = false

        // Rules run on the original text; overlapping masks combine.
        for rule in rules {
            for match in rule.regex.matches(in: text, options: [], range: scanRange) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                switch rule.style {
                case .token:
                    let keep = range.length >= 16 ? 4 : (range.length >= 8 ? 2 : 0)
                    for index in (range.location + keep)..<(range.location + range.length - keep) {
                        units[index] = maskUnit
                    }
                case .card:
                    let digits = (range.location..<(range.location + range.length))
                        .filter { isDigit(source.character(at: $0)) }
                    guard isCardNumber(digits.map { source.character(at: $0) }) else { continue }
                    for index in digits.dropLast(4) { units[index] = maskUnit }
                case .block:
                    for index in range.location..<(range.location + range.length)
                    where !isLineBreak(source.character(at: index)) {
                        units[index] = maskUnit
                    }
                }
                changed = true
            }
        }
        return changed ? String(utf16CodeUnits: units, count: units.count) : text
    }

    private static func isDigit(_ unit: unichar) -> Bool { unit >= 48 && unit <= 57 }
    private static func isLineBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    /// A known issuer prefix plus a valid Luhn checksum.
    private static func isCardNumber(_ units: [unichar]) -> Bool {
        let digits = units.map { Int($0) - 48 }
        let firstTwo = digits[0] * 10 + digits[1]
        switch digits.count {
        case 15:
            guard firstTwo == 34 || firstTwo == 37 else { return false }             // American Express
        case 16:
            let knownIssuer = digits[0] == 4                                         // Visa
                || (51...55).contains(firstTwo) || (22...27).contains(firstTwo)      // Mastercard
                || firstTwo == 35 || digits[0] == 6                                  // JCB, Discover
            guard knownIssuer else { return false }
        default:
            return false
        }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            let doubled = offset % 2 == 1 ? digit * 2 : digit
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum % 10 == 0
    }
}
