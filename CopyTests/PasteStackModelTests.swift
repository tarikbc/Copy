import AppKit
import CopyCore
import XCTest
import SwiftUI

final class PasteStackModelTests: XCTestCase {
    func testCallerDescriptionIdentifiesUnverifiedApps() {
        let unsigned = PasteStackCaller(bundleID: "example.app", canonicalPath: "/Applications/Example.app")
        XCTAssertEqual(pasteStackCallerDescription(unsigned), "Unverified app: example.app (/Applications/Example.app)")
        let partiallySigned = PasteStackCaller(bundleID: "example.app", canonicalPath: "/Applications/Example.app", signingID: "example.app")
        XCTAssertTrue(pasteStackCallerDescription(partiallySigned)?.hasPrefix("Unverified app: ") == true)
        let signed = PasteStackCaller(bundleID: "example.app", canonicalPath: "/Applications/Example.app", signingID: "example.app", certificateSHA256: "fingerprint")
        XCTAssertEqual(pasteStackCallerDescription(signed), "example.app (/Applications/Example.app)")
        XCTAssertNil(pasteStackCallerDescription(nil))
        let suspicious = PasteStackCaller(bundleID: "example\u{202E}app", canonicalPath: "/Applications/Example\n.app")
        let description = pasteStackCallerDescription(suspicious) ?? ""
        XCTAssertTrue(description.contains("⟦U+202E⟧"))
        XCTAssertTrue(description.contains("⟦U+000A⟧"))
    }

    @MainActor
    func testIncomingBatchConfirmationRequiresExplicitReplacementAndProtectsScreenSharing() throws {
        let alert = pasteStackBatchConfirmation(["first\nline", "  second  "], hideSecrets: true, hideDuringScreenSharing: true)
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Replace Stack"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", ""])
        XCTAssertEqual(alert.window.sharingType, .none)
        let view = try XCTUnwrap(alert.accessoryView as? NSHostingView<BatchReviewList>)
        XCTAssertEqual(view.rootView.texts, ["first\nline", "  second  "])
        XCTAssertTrue(view.rootView.hideSecrets)
    }

    func testBatchPreviewMasksSecretsAndExposesControlCharacters() {
        let token = "AKIA" + "IOSFODNN7EXAMPLE"
        let value = "name\u{202E}\n" + token
        let hidden = pasteStackPreviewText(value, hideSecrets: true, revealed: false)
        XCTAssertFalse(hidden.contains(token))
        XCTAssertTrue(hidden.contains("⟦U+202E⟧"))
        XCTAssertTrue(hidden.contains("⟦U+000A⟧"))
        let revealed = pasteStackPreviewText(value, hideSecrets: true, revealed: true)
        XCTAssertTrue(revealed.contains(token))
        XCTAssertFalse(revealed.contains("\u{202E}"))
    }

    func testBatchPreviewBoundsLongTextBeforeMasking() {
        let token = "AKIA" + "IOSFODNN7EXAMPLE"
        let value = String(repeating: "x", count: 260_000) + token
        XCTAssertFalse(pasteStackPreviewText(value, hideSecrets: true, revealed: false).contains(token))
        XCTAssertFalse(pasteStackPreviewText(value, hideSecrets: false, revealed: false).contains(token))
    }

    func testPathologicalGraphemeIsBoundedAndLaterPagesRequireExplicitReveal() {
        let token = "AKIA" + "IOSFODNN7EXAMPLE"
        let value = "a" + String(repeating: "\u{0301}", count: 260_000) + token
        let count = pasteStackPreviewPageCount(value)
        XCTAssertGreaterThan(count, 1)
        XCTAssertLessThanOrEqual(pasteStackPreviewText(value, hideSecrets: false, revealed: false).utf16.count, 2_000)
        XCTAssertFalse(pasteStackPreviewText(value, hideSecrets: true, revealed: false, page: count - 1).contains(token))
        XCTAssertTrue(pasteStackPreviewText(value, hideSecrets: true, revealed: true, page: count - 1).contains(token))
    }

    func testPagedPreviewDoesNotSplitSurrogatePairsAndMasksCrossPageSecrets() {
        let value = String(repeating: "x", count: 1_999) + "😀" + " " + "AKIA" + "IOSFODNN7EXAMPLE"
        XCTAssertEqual(pasteStackPreviewPageCount(value), 2)
        XCTAssertFalse(pasteStackPreviewText(value, hideSecrets: false, revealed: true).contains("�"))
        XCTAssertTrue(pasteStackPreviewText(value, hideSecrets: false, revealed: true, page: 1).hasPrefix("😀"))
        let splitSecret = String(repeating: "x", count: 1_990) + " " + "AKIA" + "IOSFODNN7EXAMPLE"
        let rendered = (0..<pasteStackPreviewPageCount(splitSecret)).map {
            pasteStackPreviewText(splitSecret, hideSecrets: true, revealed: false, page: $0)
        }.joined()
        XCTAssertFalse(rendered.contains("AKIA" + "IOSFODNN7EXAMPLE"))
    }

    @MainActor
    func testSplitEntriesNeverEnterHistoryThroughReconcileEditOrPaste() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(directory: directory)
        let store = ItemStore(writer: database.writer, blobs: BlobStore(directory: database.blobsDirectory))
        let source = try store.createTextItem("first@example.com,second@example.com")
        let model = PasteStackModel(store: store)
        model.enqueueTexts(TextSplitter.split(source.plainText!, separator: .comma))
        XCTAssertTrue(model.isActive)
        model.reconcile()
        XCTAssertEqual(model.items().map(\.plainText), ["first@example.com", "second@example.com"])
        XCTAssertEqual(try store.recentItems(limit: 10).map(\.uuid), [source.uuid])

        let entry = try XCTUnwrap(model.items().first)
        model.commitEdit(NSAttributedString(string: "edited@example.com"), for: entry)
        XCTAssertEqual(model.items().first?.plainText, "edited@example.com")
        XCTAssertNotNil(model.queue.temporaryEntry(for: entry.uuid)?.rtfData)
        let firstPaste = try XCTUnwrap(model.advanceAndResolve())
        XCTAssertEqual(String(data: firstPaste[0].data, encoding: .utf8), "edited@example.com")
        let secondPaste = try XCTUnwrap(model.advanceAndResolve())
        XCTAssertEqual(String(data: secondPaste[0].data, encoding: .utf8), "second@example.com")
        XCTAssertNil(model.advanceAndResolve())
        let history = try store.recentItems(limit: 10)
        XCTAssertEqual(history.map(\.uuid), [source.uuid])
        XCTAssertEqual(history.map(\.plainText), ["first@example.com,second@example.com"])
    }

    @MainActor
    func testIncomingBatchDoesNotReplaceQueueChangedDuringConfirmation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(directory: directory)
        let store = ItemStore(writer: database.writer, blobs: BlobStore(directory: database.blobsDirectory))
        let model = PasteStackModel(store: store)
        model.enqueueTexts(["old"])
        let observed = model.queue
        model.enqueueTexts(["added while confirming"])
        XCTAssertFalse(model.replaceWithBatch(["new"], ifUnchanged: observed))
        XCTAssertEqual(model.items().map(\.plainText), ["old", "added while confirming"])
        XCTAssertTrue(model.replaceWithBatch(["new"], ifUnchanged: model.queue))
        XCTAssertEqual(model.items().map(\.plainText), ["new"])
    }

    @MainActor
    func testBatchReplacesQueueActivatesStackAndPreservesFIFO() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(directory: directory)
        let store = ItemStore(writer: database.writer, blobs: BlobStore(directory: database.blobsDirectory))
        let model = PasteStackModel(store: store)
        model.queue.enqueue("old")
        model.queue.isLIFO = true
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.replaceWithBatch(["one", "one", "two"]))
        XCTAssertTrue(model.isActive)
        XCTAssertFalse(model.queue.isLIFO)
        for text in ["one", "one", "two"] {
            let representation = try XCTUnwrap(model.advanceAndResolve()?.first)
            XCTAssertEqual(String(data: representation.data, encoding: .utf8), text)
        }
        XCTAssertNil(model.advanceAndResolve())
        XCTAssertTrue(try store.recentItems(limit: 10).isEmpty)
    }

    @MainActor
    func testMissingHistoryItemDoesNotDropTemporaryEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(directory: directory)
        let store = ItemStore(writer: database.writer, blobs: BlobStore(directory: database.blobsDirectory))
        let model = PasteStackModel(store: store)
        model.queue.enqueue("missing-history-uuid")
        model.enqueueTexts(["same", "same"])
        model.reconcile()
        XCTAssertEqual(model.items().map(\.plainText), ["same", "same"])
        XCTAssertEqual(model.queue.count, 2)
        model.queue.isLIFO = true
        XCTAssertNotNil(model.advanceAndResolve())
        XCTAssertNotNil(model.advanceAndResolve())
        XCTAssertNil(model.advanceAndResolve())
        XCTAssertTrue(try store.recentItems(limit: 10).isEmpty)
    }
}
