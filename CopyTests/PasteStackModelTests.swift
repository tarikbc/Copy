import AppKit
import CopyCore
import XCTest

final class PasteStackModelTests: XCTestCase {
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
