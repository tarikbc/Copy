import XCTest
@testable import CopyCore

final class TextSplitTests: XCTestCase {
    func testRegexSplitsMixedSeparatorsWithoutReturningCaptureGroups() {
        let result = TextSplitter.result("one@example.com, two@example.com;three@example.com\nfour@example.com",
                                         separator: .regex, pattern: #"([,;\s]+)"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries, ["one@example.com", "two@example.com", "three@example.com", "four@example.com"])
    }

    func testRegexSupportsZeroWidthBoundariesAndUnicode() {
        XCTAssertEqual(TextSplitter.result("oneTwoThree", separator: .regex, pattern: #"(?=[A-Z])"#).entries,
                       ["one", "Two", "Three"])
        XCTAssertEqual(TextSplitter.result("🍎;café,東京", separator: .regex, pattern: "[,;]").entries,
                       ["🍎", "café", "東京"])
    }

    func testRegexInvalidAndEmptyPatternsReturnErrorsWithoutEntries() {
        for pattern in ["", "[", "(abc"] {
            let result = TextSplitter.result("one,two", separator: .regex, pattern: pattern)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.entries.isEmpty)
        }
    }

    func testRegexPreservesUnmatchedTextAndSupportsDuplicateRemoval() {
        XCTAssertEqual(TextSplitter.result("one,two", separator: .regex, pattern: ";").entries, ["one,two"])
        XCTAssertEqual(TextSplitter.result("one;two,one", separator: .regex, pattern: "[,;]",
                                           removeDuplicates: true).entries, ["one", "two"])
    }

    func testSlowRegexStopsWithoutPartialResults() {
        let result = TextSplitter.result(String(repeating: "a", count: 100_000) + "!",
                                         separator: .regex, pattern: "(a+)+$")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAISuggestionsValidateRegexAndRequireASplit() {
        let suggestion = TextSplitSuggestion.validated(separator: "regex", pattern: "[,;]+", text: "one,two;three")
        XCTAssertEqual(suggestion?.separator, .regex)
        XCTAssertEqual(suggestion?.pattern, "[,;]+")
        XCTAssertNil(TextSplitSuggestion.validated(separator: "regex", pattern: "[", text: "one,two"))
        XCTAssertNil(TextSplitSuggestion.validated(separator: "regex", pattern: ";", text: "one,two"))
        XCTAssertNil(TextSplitSuggestion.validated(separator: "unknown", pattern: "", text: "one,two"))
        XCTAssertNil(TextSplitSuggestion.validated(separator: "custom", pattern: ",", text: "one,two"))
        XCTAssertEqual(TextSplitSuggestion.validated(separator: "comma", pattern: "ignored", text: "one,two")?.pattern, "")
    }

    func testCommaListTrimsEdgesAndSkipsEmptyEntries() {
        XCTAssertEqual(TextSplitter.split(" first@example.com, ,second@example.com,\n", separator: .comma),
                       ["first@example.com", "second@example.com"])
    }

    func testDuplicatesRemainUnlessRequested() {
        let source = "a@example.com,b@example.com,a@example.com"
        XCTAssertEqual(TextSplitter.split(source, separator: .comma),
                       ["a@example.com", "b@example.com", "a@example.com"])
        XCTAssertEqual(TextSplitter.split(source, separator: .comma, removeDuplicates: true),
                       ["a@example.com", "b@example.com"])
    }

    func testNewlinesHandleWindowsAndUnicodeLineBreaks() {
        XCTAssertEqual(TextSplitter.split("one\r\ntwo\rthree\nfour\u{2028}five", separator: .newline),
                       ["one", "two", "three", "four", "five"])
    }

    func testCustomSeparatorIsLiteralAndCanContainMultipleCharacters() {
        XCTAssertEqual(TextSplitter.split("one.*two.*three", separator: .custom, custom: ".*"),
                       ["one", "two", "three"])
        XCTAssertEqual(TextSplitter.split("text", separator: .custom, custom: ""), [])
    }

    func testOtherSeparatorsAndWhitespaceOnlyInput() {
        XCTAssertEqual(TextSplitter.split("one;two", separator: .semicolon), ["one", "two"])
        XCTAssertEqual(TextSplitter.split("one\ttwo", separator: .tab), ["one", "two"])
        XCTAssertEqual(TextSplitter.split("one  two", separator: .space), ["one", "two"])
        XCTAssertEqual(TextSplitter.split(" \n ", separator: .comma), [])
    }

    func testSuggestionPrefersStructureOverSpaces() {
        XCTAssertEqual(TextSplitter.suggestedSeparator(for: "First Last,Second Last"), .comma)
        XCTAssertEqual(TextSplitter.suggestedSeparator(for: "one\ntwo\nthree"), .newline)
        XCTAssertEqual(TextSplitter.suggestedSeparator(for: "single"), nil)
    }
}
