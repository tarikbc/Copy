import XCTest
@testable import CopyCore

final class PasteStackTemporaryTests: XCTestCase {
    func testTemporaryDuplicatesHaveSeparateIdentitiesAndNoHistoryID() throws {
        var queue = PasteStackQueue()
        queue.enqueueTexts(["same", "same"])
        XCTAssertEqual(queue.count, 2)
        XCTAssertNotEqual(queue.itemUUIDs[0], queue.itemUUIDs[1])
        for uuid in queue.itemUUIDs {
            let entry = try XCTUnwrap(queue.temporaryEntry(for: uuid))
            XCTAssertNil(entry.item.id)
            XCTAssertEqual(entry.item.plainText, "same")
            XCTAssertEqual(entry.representations, [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("same".utf8))])
        }
    }

    func testTemporaryAndHistoryEntriesShareFIFOAndLIFOOrder() throws {
        var queue = PasteStackQueue()
        queue.enqueue("history")
        queue.enqueueTexts(["first", "second"])
        XCTAssertEqual(queue.advance(), "history")
        let first = try XCTUnwrap(queue.next)
        XCTAssertEqual(queue.temporaryEntry(for: first)?.text, "first")
        queue.isLIFO = true
        let second = try XCTUnwrap(queue.next)
        XCTAssertEqual(queue.temporaryEntry(for: second)?.text, "second")
        XCTAssertEqual(queue.advance(), second)
        XCTAssertNil(queue.temporaryEntry(for: second))
        XCTAssertEqual(queue.advance(), first)
        XCTAssertNil(queue.temporaryEntry(for: first))
    }

    func testRemoveAndClearDiscardTemporaryContent() throws {
        var queue = PasteStackQueue()
        queue.enqueueTexts(["one", "two"])
        let ids = queue.itemUUIDs
        queue.remove(ids[0])
        XCTAssertNil(queue.temporaryEntry(for: ids[0]))
        XCTAssertNotNil(queue.temporaryEntry(for: ids[1]))
        queue.clear()
        XCTAssertNil(queue.temporaryEntry(for: ids[1]))
        XCTAssertTrue(queue.isEmpty)
    }

    func testEditingTemporaryEntryKeepsIdentityAndUpdatedRepresentations() throws {
        var queue = PasteStackQueue()
        queue.enqueueTexts(["before"])
        let uuid = try XCTUnwrap(queue.next)
        XCTAssertTrue(queue.updateTemporaryEntry(uuid, text: "after", rtfData: Data("rtf".utf8)))
        let entry = try XCTUnwrap(queue.temporaryEntry(for: uuid))
        XCTAssertEqual(queue.itemUUIDs, [uuid])
        XCTAssertEqual(entry.item.plainText, "after")
        XCTAssertEqual(entry.representations.map(\.data), [Data("after".utf8), Data("rtf".utf8)])
        XCTAssertFalse(queue.updateTemporaryEntry("missing", text: "after", rtfData: nil))
    }
}
