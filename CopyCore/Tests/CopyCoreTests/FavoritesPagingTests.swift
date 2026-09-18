import XCTest
@testable import CopyCore

/// The shelf floats favorites to the front of its row. If the history query bounded
/// favorites by the same recency window as everything else, an old favorite would be
/// invisible until paging happened to reach it, then appear at position 0 and shift
/// every card sideways under the user's cursor mid-scroll. These pin down that
/// favorites are exempt from the page limit, so the front of the row never moves as
/// pages load.
final class FavoritesPagingTests: XCTestCase {
    /// Saves `count` items oldest first, one second apart, so `lastUsedAt` ordering is
    /// deterministic rather than dependent on how fast the test machine runs.
    @discardableResult
    private func seed(_ store: ItemStore, count: Int, from start: Date) throws -> [ClipItem] {
        try (0..<count).map { index in
            try store.save(makeText("item \(index)"), now: start.addingTimeInterval(Double(index)))
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testOldFavoriteSurvivesThePageLimit() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 150, from: base)
        let oldest = try XCTUnwrap(items.first)
        try store.setFavorite(itemID: try XCTUnwrap(oldest.id), true)

        let page = try store.recentPage(filter: SearchFilter(), limit: 100)

        XCTAssertTrue(page.contains { $0.uuid == oldest.uuid },
                      "the oldest favorite must load even though 149 newer items exist")
    }

    func testLimitStillBoundsNonFavorites() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 150, from: base)
        try store.setFavorite(itemID: try XCTUnwrap(items[0].id), true)

        let page = try store.recentPage(filter: SearchFilter(), limit: 100)

        XCTAssertEqual(page.filter { !$0.isFavorite }.count, 100,
                       "favorites are exempt from the limit; everything else is not")
    }

    /// The regression test for the jump: the favorites at the front of the row must be
    /// identical at every window size, so growing the window never reorders the front.
    func testFavoriteSetIsIdenticalAtEveryWindowSize() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 400, from: base)
        for index in [0, 7, 120, 399] {
            try store.setFavorite(itemID: try XCTUnwrap(items[index].id), true)
        }

        let atFirstPage = try store.recentPage(filter: SearchFilter(), limit: 100)
            .filter(\.isFavorite).map(\.uuid)
        let afterGrowth = try store.recentPage(filter: SearchFilter(), limit: 300)
            .filter(\.isFavorite).map(\.uuid)
        let fullHistory = try store.recentPage(filter: SearchFilter(), limit: 1_000)
            .filter(\.isFavorite).map(\.uuid)

        XCTAssertEqual(atFirstPage.count, 4)
        XCTAssertEqual(atFirstPage, afterGrowth)
        XCTAssertEqual(atFirstPage, fullHistory)
    }

    func testFavoritesComeBackNewestFirst() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 200, from: base)
        try store.setFavorite(itemID: try XCTUnwrap(items[10].id), true)
        try store.setFavorite(itemID: try XCTUnwrap(items[190].id), true)

        let favorites = try store.recentPage(filter: SearchFilter(), limit: 100)
            .filter(\.isFavorite)

        XCTAssertEqual(favorites.map(\.uuid), [items[190].uuid, items[10].uuid])
    }

    func testNoDuplicateWhenAFavoriteIsAlsoInsideTheWindow() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 50, from: base)
        try store.setFavorite(itemID: try XCTUnwrap(items[49].id), true)

        let page = try store.recentPage(filter: SearchFilter(), limit: 100)

        XCTAssertEqual(page.count, 50, "a recent favorite must not be returned twice")
        XCTAssertEqual(Set(page.map(\.uuid)).count, 50)
    }

    /// Facets still constrain favorites; exemption is from the limit, not from the query.
    func testFacetsStillApplyToFavorites() throws {
        let store = try makeTempStore()
        let text = try store.save(makeText("a note"), now: base)
        let link = try store.save(CapturedItem(kind: .link, plainText: "https://example.com",
                                               hashData: Data("https://example.com".utf8),
                                               representations: [CapturedRepresentation(
                                                   uti: "public.utf8-plain-text",
                                                   data: Data("https://example.com".utf8))],
                                               sourceBundleID: nil, sourceAppName: nil),
                                  now: base.addingTimeInterval(1))
        try store.setFavorite(itemID: try XCTUnwrap(text.id), true)
        try store.setFavorite(itemID: try XCTUnwrap(link.id), true)

        var filter = SearchFilter()
        filter.kinds = [.link]
        let page = try store.recentPage(filter: filter, limit: 100)

        XCTAssertEqual(page.map(\.kind), [.link],
                       "a favorite of the wrong kind must not bypass the kind facet")
    }

    func testFavoritesOnlyFilterReturnsEveryFavorite() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 150, from: base)
        try store.setFavorite(itemID: try XCTUnwrap(items[0].id), true)
        try store.setFavorite(itemID: try XCTUnwrap(items[149].id), true)

        var filter = SearchFilter()
        filter.favoritesOnly = true
        let page = try store.recentPage(filter: filter, limit: 100)

        XCTAssertEqual(page.count, 2)
        XCTAssertTrue(page.allSatisfy(\.isFavorite))
    }

    func testEmptyHistoryReturnsNothing() throws {
        let store = try makeTempStore()
        XCTAssertEqual(try store.recentPage(filter: SearchFilter(), limit: 100).count, 0)
    }
    func testDisabledFavoritesUseOneRecencyWindowAndKeepSavedMarks() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 150, from: base)
        try store.setFavorite(itemID: XCTUnwrap(items[0].id), true)
        try store.setFavorite(itemID: XCTUnwrap(items[149].id), true)
        let page = try store.recentPage(filter: SearchFilter(), limit: 100, favoritesFirst: false)
        XCTAssertEqual(page.map(\.uuid), Array(items.suffix(100).reversed()).map(\.uuid))
        let grown = try store.recentPage(filter: SearchFilter(), limit: 150, favoritesFirst: false)
        XCTAssertEqual(Array(grown.prefix(100)).map(\.uuid), page.map(\.uuid))
        XCTAssertEqual(grown.last?.uuid, items[0].uuid)
        XCTAssertTrue(try XCTUnwrap(store.item(uuid: items[0].uuid)).isFavorite)
        let enabled = try store.recentPage(filter: SearchFilter(), limit: 100)
        XCTAssertEqual(Set(enabled.prefix(2).map(\.uuid)), Set([items[0].uuid, items[149].uuid]))
        _ = try store.prune(olderThan: base.addingTimeInterval(200), maxItems: nil)
        XCTAssertNotNil(try store.item(uuid: items[0].uuid))
    }

    func testDisabledFavoritesTextSearchStillFiltersAndPages() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 150, from: base)
        try store.setFavorite(itemID: XCTUnwrap(items[0].id), true)
        let filter = SearchFilter(text: "item")
        let result = try store.search(filter: filter, limit: 100, favoritesFirst: false)
        XCTAssertEqual(result.map(\.uuid), Array(items.suffix(100).reversed()).map(\.uuid))
        XCTAssertEqual(try store.search(filter: SearchFilter(text: "missing"), favoritesFirst: false).count, 0)
    }

    func testDisabledFavoritesObservationUsesTheSameWindow() throws {
        let store = try makeTempStore()
        let items = try seed(store, count: 5, from: base)
        try store.setFavorite(itemID: XCTUnwrap(items[0].id), true)
        let received = expectation(description: "recency observation")
        let token = store.observeRecent(filter: SearchFilter(), limit: 2, favoritesFirst: false,
            onError: { error in XCTFail("\(error)"); received.fulfill() },
            onChange: { page in
                XCTAssertEqual(page.map(\.uuid), [items[4].uuid, items[3].uuid])
                received.fulfill()
            })
        wait(for: [received], timeout: 3)
        token.cancel()
    }

    func testFavoritesSuggestionCanBeHidden() {
        let normal = searchSuggestions(prefix: "fav", apps: [], pinboards: [], query: SearchQuery())
        XCTAssertTrue(normal.contains { $0.token == .favorites })
        let hidden = searchSuggestions(prefix: "fav", apps: [], pinboards: [], query: SearchQuery(), includeFavorites: false)
        XCTAssertFalse(hidden.contains { $0.token == .favorites })
    }

}
