import XCTest
@testable import CopyCore

func makeTempStores() throws -> (ItemStore, PinboardStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopyTests-\(UUID().uuidString)")
    let dbm = try DatabaseManager(directory: dir)
    return (ItemStore(writer: dbm.writer, blobs: BlobStore(directory: dbm.blobsDirectory)),
            PinboardStore(writer: dbm.writer))
}

final class PinboardStoreTests: XCTestCase {
    func testCreateListRenameDelete() throws {
        let (_, pinboards) = try makeTempStores()
        let work = try pinboards.create(name: "Work", symbol: "briefcase")
        let snippets = try pinboards.create(name: "Snippets", symbol: "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(try pinboards.all().map(\.name), ["Work", "Snippets"])
        try pinboards.rename(id: work.id!, to: "Projects")
        try pinboards.setSymbol(id: work.id!, "folder")
        let reloaded = try pinboards.all()
        XCTAssertEqual(reloaded[0].name, "Projects")
        XCTAssertEqual(reloaded[0].symbol, "folder")
        try pinboards.delete(id: snippets.id!)
        XCTAssertEqual(try pinboards.all().count, 1)
    }

    func testMembershipAddRemoveAndOrdering() throws {
        let (store, pinboards) = try makeTempStores()
        let board = try pinboards.create(name: "Board", symbol: "pin")
        let a = try store.save(makeText("first"))
        let b = try store.save(makeText("second"))
        try pinboards.add(itemID: a.id!, to: board.id!)
        try pinboards.add(itemID: b.id!, to: board.id!)
        try pinboards.add(itemID: b.id!, to: board.id!) // idempotent
        XCTAssertEqual(try pinboards.items(in: board.id!).map(\.plainText), ["second", "first"])
        XCTAssertEqual(try pinboards.pinboardIDs(forItemID: a.id!), [board.id!])
        try pinboards.remove(itemID: a.id!, from: board.id!)
        XCTAssertEqual(try pinboards.items(in: board.id!).count, 1)
    }

    func testDeletingPinboardKeepsItems() throws {
        let (store, pinboards) = try makeTempStores()
        let board = try pinboards.create(name: "Doomed", symbol: "pin")
        let item = try store.save(makeText("survivor"))
        try pinboards.add(itemID: item.id!, to: board.id!)
        try pinboards.delete(id: board.id!)
        XCTAssertEqual(try store.recentItems(limit: 10).count, 1)
    }

    func testMovePinboardsBeforeAndAfterEachOther() throws {
        let (_, pinboards) = try makeTempStores()
        let a = try pinboards.create(name: "A", symbol: "pin")
        let b = try pinboards.create(name: "B", symbol: "pin")
        let c = try pinboards.create(name: "C", symbol: "pin")

        try pinboards.move(id: a.id!, relativeTo: c.id!, placeAfterTarget: true)
        XCTAssertEqual(try pinboards.all().map(\.name), ["B", "C", "A"])

        try pinboards.move(id: c.id!, relativeTo: b.id!, placeAfterTarget: false)
        XCTAssertEqual(try pinboards.all().map(\.name), ["C", "B", "A"])

        try pinboards.move(id: b.id!, relativeTo: a.id!, placeAfterTarget: false)
        XCTAssertEqual(try pinboards.all().map(\.name), ["C", "B", "A"],
                       "dropping into the board's existing gap should be a no-op")
    }

    func testMoveIgnoresUnknownOrSamePinboardWithoutChangingOrder() throws {
        let (_, pinboards) = try makeTempStores()
        let a = try pinboards.create(name: "A", symbol: "pin")
        _ = try pinboards.create(name: "B", symbol: "pin")

        try pinboards.move(id: a.id!, relativeTo: a.id!, placeAfterTarget: true)
        try pinboards.move(id: 9_999, relativeTo: a.id!, placeAfterTarget: false)

        XCTAssertEqual(try pinboards.all().map(\.name), ["A", "B"])
    }

    func testClearHistorySparesPinboardMembers() throws {
        let (store, pinboards) = try makeTempStores()
        let board = try pinboards.create(name: "Keep", symbol: "pin")
        let kept = try store.save(makeText("kept"))
        _ = try store.save(makeText("tossed"))
        try pinboards.add(itemID: kept.id!, to: board.id!)
        try store.clearHistory(keepFavorites: true)
        XCTAssertEqual(try store.recentItems(limit: 10).map(\.plainText), ["kept"])
    }

    func testReplaceContentEditsInPlace() throws {
        let (store, _) = try makeTempStores()
        let item = try store.save(makeText("orig"))
        let edited = try store.replaceContent(itemID: item.id!, with: "edited text")
        XCTAssertEqual(edited.id, item.id)
        XCTAssertEqual(edited.plainText, "edited text")
        XCTAssertEqual(edited.kind, .text)
        let reps = try store.representations(forItemID: item.id!)
        XCTAssertEqual(reps.map(\.uti), ["public.utf8-plain-text"])
        XCTAssertEqual(try store.search("edited").count, 1)
        XCTAssertEqual(try store.search("orig").count, 0)
    }

    func testReplaceContentMergesOnHashCollision() throws {
        let (store, _) = try makeTempStores()
        let target = try store.save(makeText("winner"), now: Date(timeIntervalSince1970: 1000))
        let edited = try store.save(makeText("loser"))
        let survivor = try store.replaceContent(itemID: edited.id!, with: "winner",
                                                now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(survivor.id, target.id)
        XCTAssertEqual(survivor.lastUsedAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(try store.recentItems(limit: 10).count, 1)
    }

    func testDedupRefreshesKind() throws {
        let (store, _) = try makeTempStores()
        _ = try store.save(makeText("hello"))
        let styled = CapturedItem(
            kind: .richText, plainText: "hello", hashData: Data("hello".utf8),
            representations: [
                CapturedRepresentation(uti: "public.rtf", data: Data("rtf".utf8)),
                CapturedRepresentation(uti: "public.utf8-plain-text", data: Data("hello".utf8)),
            ],
            sourceBundleID: nil, sourceAppName: nil)
        let merged = try store.save(styled)
        XCTAssertEqual(merged.kind, .richText)
    }
}
