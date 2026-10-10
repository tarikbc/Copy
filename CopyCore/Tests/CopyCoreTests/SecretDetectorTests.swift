import XCTest
@testable import CopyCore

/// Every key here is fake, assembled from pieces so secret scanners ignore it.
final class SecretDetectorTests: XCTestCase {
    private let awsKey = "AKIA" + "IOSFODNN7EXAMPLE"
    private let githubToken = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz0123456789"
    private let openAIKey = "sk" + "-proj-" + "FAKEfakeFAKEfake1234567890abcd"
    private let stripeKey = "sk" + "_test_" + "FAKE0000FAKE0000FAKE0000"
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0"
        + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    private func mask(_ text: String) -> String { SecretDetector.masked(text) }
    private let dot = String(SecretDetector.maskCharacter)

    // MARK: Provider formats

    func testMasksProviderKeysKeepingBothEnds() {
        XCTAssertEqual(mask(awsKey), "AKIA" + String(repeating: dot, count: 12) + "MPLE")
        XCTAssertEqual(mask(githubToken), "ghp_" + String(repeating: dot, count: 32) + "6789")
        XCTAssertTrue(mask(openAIKey).hasPrefix("sk-p" + dot))
        XCTAssertTrue(mask(openAIKey).hasSuffix(dot + "abcd"))
        XCTAssertTrue(SecretDetector.containsSecret(stripeKey))
        XCTAssertTrue(SecretDetector.containsSecret(jwt))
    }

    func testMasksOnlyTheSecretInsideSurroundingText() {
        let text = "Use \(awsKey) for the staging bucket."
        XCTAssertEqual(mask(text), "Use AKIA" + String(repeating: dot, count: 12) + "MPLE for the staging bucket.")
    }

    func testBearerTokenIsMaskedButTheHeaderNameStays() {
        let masked = mask("Authorization: Bearer abcdef0123456789abcdef0123456789")
        XCTAssertTrue(masked.hasPrefix("Authorization: Bearer abcd" + dot))
        XCTAssertFalse(masked.contains("0123456789abcdef"))
    }

    // MARK: name = value

    func testMasksValueOfEnvStyleAssignmentButNotItsName() {
        let masked = mask("DB_PASSWORD=Tr0ub4dor-and-3-more")
        XCTAssertTrue(masked.hasPrefix("DB_PASSWORD=Tr0u" + dot))
        XCTAssertTrue(masked.hasSuffix(dot + "more"))
    }

    func testMasksQuotedValueInJSONAndCode() {
        XCTAssertTrue(SecretDetector.containsSecret(#"{ "api_key": "a1b2c3d4e5f6g7h8" }"#))
        XCTAssertTrue(SecretDetector.containsSecret(#"let clientSecret = "a1b2c3d4e5f6g7h8""#))
        XCTAssertTrue(mask(#"password: 'hunter2hunter2'"#).hasPrefix("password: 'hu" + dot))
    }

    func testMasksTokenInURLQueryButKeepsTheRestOfTheURL() {
        let masked = mask("https://example.com/hook?access_token=a1b2c3d4e5f6g7h8&page=2")
        XCTAssertTrue(masked.hasPrefix("https://example.com/hook?access_token=a1b2" + dot))
        XCTAssertTrue(masked.hasSuffix("g7h8&page=2"))
    }

    func testMasksEachSecretInAMultiLineEnvFile() {
        let env = "APP_NAME=Copy\nAPI_KEY=\(openAIKey)\nSTRIPE_SECRET=\(stripeKey)\nDEBUG=true"
        let lines = mask(env).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "APP_NAME=Copy")
        XCTAssertTrue(lines[1].hasPrefix("API_KEY=sk-p" + dot))
        XCTAssertTrue(lines[2].hasPrefix("STRIPE_SECRET=sk_t" + dot))
        XCTAssertEqual(lines[3], "DEBUG=true")
    }

    // MARK: Cards and private keys

    func testCardNumberKeepsOnlyLastFourDigitsAndItsSpacing() {
        let group = String(repeating: dot, count: 4)
        XCTAssertEqual(mask("4242 4242 4242 4242"), "\(group) \(group) \(group) 4242")
        XCTAssertEqual(mask("Card: 4111-1111-1111-1111."), "Card: \(group)-\(group)-\(group)-1111.")
        XCTAssertEqual(mask("378282246310005"), String(repeating: dot, count: 11) + "0005")   // Amex, 15 digits
    }

    func testDigitRunsThatAreNotCardsStayVisible() {
        for text in [
            "1234 5678 9012 3456",       // unknown issuer prefix
            "4242 4242 4242 4241",       // right prefix, wrong checksum
            "1728561234567",             // 13 digits: a millisecond timestamp
            "42424242424242424242",      // 20 digits
            "+1 (555) 010-1234",
            "Order 4242424242424242x",   // runs into a letter
        ] {
            XCTAssertEqual(mask(text), text, text)
        }
    }

    func testPrivateKeyBodyIsHiddenAndItsLinesKept() {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        let hidden = String(repeating: dot, count: 15)
        XCTAssertEqual(mask("\(begin)\nb3BlbnNzaC1rZXk\nAAAAB3NzaC1yc2E\n\(end)"),
                       "\(begin)\n\(hidden)\n\(hidden)\n\(end)")
    }

    func testUnterminatedPrivateKeyIsHiddenToTheEnd() {
        XCTAssertEqual(mask("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg"),
                       "-----BEGIN PRIVATE KEY-----\n" + String(repeating: dot, count: 14))
    }

    // MARK: Ordinary text

    func testOrdinaryTextIsLeftAlone() {
        for text in [
            "9d352d5a1b2c3d4e5f60718293a4b5c6d7e8f901",          // git commit hash
            "6F9619FF-8B86-D011-B42D-00C04FC964FF",              // UUID
            "#4C9DFF",
            "https://github.com/tarikbc/Copy/pull/18",
            "my password is on a sticky note",
            "The token: please bring your ticket to the desk",
            "Standup at 10:30, demo the smart search and paste stack.",
            "the task-management-system-design-document",        // "sk-" inside a word
            "",
        ] {
            XCTAssertFalse(SecretDetector.containsSecret(text), text)
        }
    }

    /// Identifiers, labels, paths and references are not secret values.
    func testCodeThatOnlyNamesASecretIsLeftAlone() {
        for text in [
            #"let passwordLabel = "Enter your password""#,        // quoted, but prose
            "login(password=user_password1)",                    // lowercase kwarg
            "token = session2Token",                              // spaced assignment to an identifier
            "password = hashPassword(input1)",
            "let apiKey = config.value(for: key2)",
            "SECRET_PATH=/etc/app/secrets2",                      // a path
            "API_KEY=$OPENAI_API_KEY_V2",                         // a variable reference
            #"callbackToken = "https://example.com/v2/callback""#, // a URL
            "DEBUG_TOKEN=true",                                   // too short, no digit
        ] {
            XCTAssertEqual(mask(text), text, text)
        }
    }

    // MARK: Titles

    func testDisplayTitleMasksSecretsOnlyWhenAskedAndNeverATitleTheUserTyped() {
        var item = ClipItem(
            id: 1, uuid: "u", kind: .text, createdAt: Date(), lastUsedAt: Date(),
            plainText: awsKey, linkTitle: nil, appBundleID: nil, appName: nil,
            contentHash: "h", sizeBytes: 20, isFavorite: false)

        XCTAssertEqual(item.displayTitle, awsKey)
        XCTAssertEqual(item.displayTitle(hidingSecrets: false), awsKey)
        XCTAssertEqual(item.displayTitle(hidingSecrets: true), mask(awsKey))

        item.title = "AWS staging key"
        XCTAssertEqual(item.displayTitle(hidingSecrets: true), "AWS staging key")
    }

    // MARK: Guarantees the UI relies on

    func testMaskingNeverChangesTheLength() {
        for text in [awsKey, githubToken, jwt, "API_KEY=\(openAIKey)", "4242 4242 4242 4242",
                     "héllo 👋 \(stripeKey) wörld", "-----BEGIN PRIVATE KEY-----\r\nabc\r\ndef\r\n"] {
            let masked = mask(text)
            XCTAssertEqual(masked.count, text.count, text)
            XCTAssertEqual(masked.utf16.count, text.utf16.count, text)
        }
    }

    func testMaskedPrefixHidesASecretTheCutoffSlicesThrough() {
        let text = "note " + githubToken
        // The cutoff lands 10 characters into the token; none of its hidden part may show.
        XCTAssertEqual(SecretDetector.maskedPrefix(text, count: 15), "note ghp_" + String(repeating: dot, count: 6))
        XCTAssertEqual(SecretDetector.maskedPrefix("plain text", count: 5), "plain")
    }

    /// Guards against quadratic backtracking on a long run of key-like characters.
    func testAHugeRunOfKeyLikeCharactersDoesNotHang() {
        let blob = String(repeating: "aGVsbG8gd29ybGQ", count: 20_000)   // 300k characters
        let started = Date()
        XCTAssertFalse(SecretDetector.containsSecret(blob))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
