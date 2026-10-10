import XCTest
@testable import CopyCore

/// `ItemStore.pruneSecrets`. Every key here is fake (see `SecretDetectorTests`).
final class SecretRetentionTests: XCTestCase {
    private let secret = "API_KEY=" + "sk" + "-proj-" + "FAKEfakeFAKEfake1234567890abcd"
    private let otherSecret = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz0123456789"

    private let copiedAt = Date(timeIntervalSince1970: 1_000)
    private let cutoff = Date(timeIntervalSince1970: 2_000)
    private let afterCutoff = Date(timeIntervalSince1970: 3_000)

    private func texts(in store: ItemStore) throws -> Set<String> {
        Set(try store.recentItems(limit: 100).compactMap(\.plainText))
    }

    func testDeletesOldSecretsAndNothingElse() throws {
        let store = try makeTempStore()
        try store.save(makeText(secret), now: copiedAt)
        try store.save(makeText("an old note with nothing to hide"), now: copiedAt)
        try store.save(makeText(otherSecret), now: afterCutoff)

        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 1)
        XCTAssertEqual(try texts(in: store), ["an old note with nothing to hide", otherSecret])
    }

    func testSparesFavoritesAndPinboardMembers() throws {
        let (store, pinboards) = try makeTempStores()
        let favorite = try store.save(makeText(secret), now: copiedAt)
        let pinned = try store.save(makeText(otherSecret), now: copiedAt)
        try store.setFavorite(itemID: favorite.id!, true)
        let board = try pinboards.create(name: "Keys", symbol: "key")
        try pinboards.add(itemID: pinned.id!, to: board.id!)

        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 0)
        XCTAssertEqual(try texts(in: store), [secret, otherSecret])

        // Letting go of the favorite makes it deletable again.
        try store.setFavorite(itemID: favorite.id!, false)
        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 1)
        XCTAssertEqual(try texts(in: store), [otherSecret])
    }

    /// The clock is when the item was first copied; using or re-copying it doesn't extend it.
    func testPastingOrCopyingAgainDoesNotExtendTheClock() throws {
        let store = try makeTempStore()
        let pasted = try store.save(makeText(secret), now: copiedAt)
        try store.touch(itemID: pasted.id!, now: afterCutoff)
        try store.save(makeText(otherSecret), now: copiedAt)
        try store.save(makeText(otherSecret), now: afterCutoff)   // same content: dedups, bumps lastUsedAt

        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 2)
        XCTAssertTrue(try texts(in: store).isEmpty)
    }

    func testAnEditIsCheckedAgain() throws {
        let store = try makeTempStore()
        let becomesSecret = try store.save(makeText("just a note"), now: copiedAt)
        let stopsBeingSecret = try store.save(makeText(secret), now: copiedAt)

        // A first run settles both, with nothing old enough to delete.
        XCTAssertEqual(try store.pruneSecrets(olderThan: Date(timeIntervalSince1970: 500)), 0)

        try store.replaceContent(itemID: becomesSecret.id!, with: otherSecret, now: afterCutoff)
        try store.replaceContent(itemID: stopsBeingSecret.id!, with: "the key was rotated", now: afterCutoff)

        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 1)
        XCTAssertEqual(try texts(in: store), ["the key was rotated"])
    }

    func testClassifiesAHistoryLargerThanOneBatch() throws {
        let store = try makeTempStore()
        let total = ItemStore.deleteChunkSize * 2 + 25
        for index in 0..<total {
            // Every third item is a secret.
            let text = index % 3 == 0 ? "TOKEN_\(index)=abc123def456ghi\(index)" : "note \(index)"
            try store.save(makeText(text), now: copiedAt)
        }

        let expected = (0..<total).filter { $0 % 3 == 0 }.count
        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), expected)
        XCTAssertEqual(try store.recentItems(limit: 5_000).count, total - expected)
    }

    func testImagesAndFilesAreNeverTreatedAsSecrets() throws {
        let store = try makeTempStore()
        // A file whose name happens to look like a key assignment.
        try store.save(CapturedItem(
            kind: .file, plainText: secret, hashData: Data("file".utf8),
            representations: [CapturedRepresentation(uti: "public.file-url", data: Data("file:///tmp/x".utf8))],
            sourceBundleID: "com.test.app", sourceAppName: "TestApp"), now: copiedAt)

        XCTAssertEqual(try store.pruneSecrets(olderThan: cutoff), 0)
        XCTAssertEqual(try store.recentItems(limit: 10).count, 1)
    }
}
