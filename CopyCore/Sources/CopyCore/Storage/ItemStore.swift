import Foundation
import GRDB

/// One row of `ItemStore.storageBreakdown()`: a kind, how many clearable items it has, and
/// their total stored bytes.
public struct StorageUsage: Equatable, Sendable {
    public let kind: ItemKind
    public let count: Int
    public let bytes: Int

    public init(kind: ItemKind, count: Int, bytes: Int) {
        self.kind = kind
        self.count = count
        self.bytes = bytes
    }
}

public struct ItemStore {
    public static let inlineThreshold = 65_536
    public static let deleteChunkSize = 500
    public static let userCreatedAppName = "Copy"
    public static let userCreatedAppBundleID = "com.tarikbc.Copy"

    private let writer: any DatabaseWriter
    private let blobs: BlobStore

    public init(writer: any DatabaseWriter, blobs: BlobStore) {
        self.writer = writer
        self.blobs = blobs
    }

    @discardableResult
    public func save(_ captured: CapturedItem, now: Date = Date()) throws -> ClipItem {
        let hash = BlobStore.key(for: captured.hashData)
        return try writer.write { db in
            if var existing = try ClipItem.filter(Column("contentHash") == hash).fetchOne(db) {
                existing.lastUsedAt = now
                existing.appBundleID = captured.sourceBundleID
                existing.appName = captured.sourceAppName
                existing.sizeBytes = captured.representations.reduce(0) { $0 + $1.data.count }
                existing.kind = captured.kind
                try existing.update(db)

                // Exclude the favicon representation from both the old-blob-key lookup
                // and the wipe below: a favicon is set out-of-band (`setFavicon`) after
                // the item is first saved, so re-copying the same content and hitting
                // this dedup branch must not erase it.
                let oldKeys = try String.fetchAll(db, sql:
                    "SELECT DISTINCT blobKey FROM representation WHERE itemId = ? AND blobKey IS NOT NULL AND uti != ?",
                    arguments: [existing.id!, CopyPasteboard.faviconUTI])
                try Representation.filter(
                    Column("itemId") == existing.id! && Column("uti") != CopyPasteboard.faviconUTI
                ).deleteAll(db)
                try insertRepresentations(captured.representations, itemID: existing.id!, in: db)
                try cleanOrphanBlobs(oldKeys, in: db)
                return existing
            }
            var item = ClipItem(
                id: nil, uuid: UUID().uuidString, kind: captured.kind,
                createdAt: now, lastUsedAt: now,
                plainText: captured.plainText, linkTitle: nil,
                appBundleID: captured.sourceBundleID, appName: captured.sourceAppName,
                contentHash: hash,
                sizeBytes: captured.representations.reduce(0) { $0 + $1.data.count },
                isFavorite: false
            )
            try item.insert(db)
            try insertRepresentations(captured.representations, itemID: item.id!, in: db)
            return item
        }
    }

    private func insertRepresentations(_ reps: [CapturedRepresentation], itemID: Int64, in db: Database) throws {
        for rep in reps {
            var record: Representation
            if rep.data.count > Self.inlineThreshold {
                let key = try blobs.store(rep.data)
                record = Representation(id: nil, itemId: itemID, uti: rep.uti, inlineData: nil, blobKey: key)
            } else {
                record = Representation(id: nil, itemId: itemID, uti: rep.uti, inlineData: rep.data, blobKey: nil)
            }
            try record.insert(db)
        }
    }

    private func cleanOrphanBlobs(_ keys: [String], in db: Database) throws {
        for key in keys {
            let stillUsed = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM representation WHERE blobKey = ?", arguments: [key]) ?? 0
            if stillUsed == 0 { blobs.delete(key: key) }
        }
    }

    public func recentItems(kinds: Set<ItemKind>? = nil, limit: Int = 50) throws -> [ClipItem] {
        try writer.read { db in
            var request = ClipItem.order(Column("lastUsedAt").desc).limit(limit)
            if let kinds {
                request = request.filter(kinds.map(\.rawValue).contains(Column("kind")))
            }
            return try request.fetchAll(db)
        }
    }

    /// Looks up a single item by its stable uuid, regardless of how far back it sits
    /// in `lastUsedAt` order — unlike `recentItems`, this isn't bounded by a `limit`,
    /// so it's the right tool for resolving a uuid held elsewhere (e.g. a Paste Stack
    /// queue entry) that may have aged out of any "recent" window.
    public func item(uuid: String) throws -> ClipItem? {
        try writer.read { db in
            try ClipItem.filter(Column("uuid") == uuid).fetchOne(db)
        }
    }

    public func representations(forItemID id: Int64) throws -> [CapturedRepresentation] {
        let records = try writer.read { db in
            try Representation.filter(Column("itemId") == id).fetchAll(db)
        }
        return records.compactMap { rep in
            if let data = rep.inlineData {
                return CapturedRepresentation(uti: rep.uti, data: data)
            }
            if let key = rep.blobKey, let data = blobs.data(forKey: key) {
                return CapturedRepresentation(uti: rep.uti, data: data)
            }
            return nil
        }
    }

    /// A self-contained archive snapshot of one item (every field plus its representation
    /// bytes), in the same shape `importArchived` consumes. The app captures this before
    /// deleting an item so a later undo can re-insert it faithfully. Kept in CopyCore
    /// because `ArchivedItem`'s memberwise initializer is internal to this module.
    public func archivedSnapshot(itemID: Int64) throws -> ArchivedItem {
        let reps = try representations(forItemID: itemID)
        return try writer.read { db in
            guard let item = try ClipItem.fetchOne(db, key: itemID) else {
                throw DatabaseError(message: "item not found")
            }
            return ArchivedItem(
                kind: item.kind.rawValue,
                plainText: item.plainText,
                title: item.title,
                linkTitle: item.linkTitle,
                recognizedText: item.recognizedText,
                appName: item.appName,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                contentHash: item.contentHash,
                isFavorite: item.isFavorite,
                representations: reps.map { ArchivedRep(uti: $0.uti, dataBase64: $0.data.base64EncodedString()) }
            )
        }
    }

    /// `pinboardID` is deliberately the last parameter (rather than sitting beside
    /// `kinds`) so existing positional call sites like `search(query, limit: 10)`
    /// (the `SearchClipboardIntent` AppIntent, which searches globally) keep compiling
    /// unchanged and stay unscoped.
    public func search(_ query: String, kinds: Set<ItemKind>? = nil, limit: Int = 50, pinboardID: Int64? = nil) throws -> [ClipItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        var sql = """
            SELECT item.* FROM item
            JOIN item_fts ON item_fts.rowid = item.id
            WHERE item_fts MATCH ?
            """
        var arguments: [any DatabaseValueConvertible] = [pattern]
        if let kinds {
            let names = kinds.map(\.rawValue).sorted()
            sql += " AND item.kind IN (\(names.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: names)
        }
        if let pinboardID {
            sql += " AND item.id IN (SELECT itemId FROM pinboard_item WHERE pinboardId = ?)"
            arguments.append(pinboardID)
        }
        sql += " ORDER BY item.lastUsedAt DESC LIMIT ?"
        arguments.append(limit)
        return try writer.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Faceted search (see `SearchFilter`): FTS-matches `filter.text` when present, then
    /// AND-applies the app/kind/date/favorites/pinboard facets. With no text it's a plain
    /// `SELECT` (no FTS), so facet-only queries work without a text pattern.
    /// Results page the same way history does, so favorites get the same exemption from
    /// `limit` for the same reason — see `fetchRecentPage`. Matching favorites come first
    /// and in full; everything else is bounded.
    /// Set `favoritesFirst` to false for one bounded recency window, without changing marks.
    public func search(filter: SearchFilter, limit: Int = 100, favoritesFirst: Bool = true) throws -> [ClipItem] {
        if !favoritesFirst {
            guard let query = searchQuery(filter, isFavorite: nil, limit: limit) else { return [] }
            return try writer.read { db in
                try ClipItem.fetchAll(db, sql: query.sql, arguments: StatementArguments(query.arguments))
            }
        }
        guard let favorites = searchQuery(filter, isFavorite: true, limit: nil),
              let rest = searchQuery(filter, isFavorite: false, limit: limit) else { return [] }
        return try writer.read { db in
            try ClipItem.fetchAll(db, sql: favorites.sql,
                                  arguments: StatementArguments(favorites.arguments))
                + ClipItem.fetchAll(db, sql: rest.sql,
                                    arguments: StatementArguments(rest.arguments))
        }
    }

    /// Builds one half of `search(filter:)`: the matching rows on one side of the favorite
    /// split, newest first, optionally bounded. Returns nil when the free text can't compile
    /// to an FTS pattern, which the caller treats as "no results".
    private func searchQuery(_ filter: SearchFilter, isFavorite: Bool?, limit: Int?)
        -> (sql: String, arguments: [any DatabaseValueConvertible])? {
        var sql: String
        var arguments: [any DatabaseValueConvertible] = []
        if filter.hasText {
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: filter.text) else { return nil }
            sql = """
                SELECT item.* FROM item
                JOIN item_fts ON item_fts.rowid = item.id
                WHERE item_fts MATCH ?
                """
            arguments.append(pattern)
        } else {
            sql = "SELECT item.* FROM item WHERE 1"
        }
        let facets = facetClauses(filter)
        sql += facets.sql
        arguments.append(contentsOf: facets.arguments)
        // A literal 0/1 from a Bool, not caller text, so there's nothing to bind or escape.
        if let isFavorite { sql += " AND item.isFavorite = \(isFavorite ? 1 : 0)" }
        sql += " ORDER BY item.lastUsedAt DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments.append(limit)
        }
        return (sql, arguments)
    }

    /// The AND-ed WHERE fragment (leading `" AND …"`) and bound arguments for a filter's
    /// non-text facets, shared by `search(filter:)` and `observeRecent(filter:)`.
    private func facetClauses(_ filter: SearchFilter) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var sql = ""
        var arguments: [any DatabaseValueConvertible] = []
        if let appBundleID = filter.appBundleID {
            sql += " AND item.appBundleID = ?"
            arguments.append(appBundleID)
        }
        if let kindFacet = kindFacet(filter) {
            sql += " AND \(kindFacet.sql)"
            arguments.append(contentsOf: kindFacet.arguments)
        }
        if let range = filter.dateRange {
            sql += " AND item.lastUsedAt >= ? AND item.lastUsedAt < ?"
            arguments.append(range.start)
            arguments.append(range.end)
        }
        if filter.favoritesOnly {
            sql += " AND item.isFavorite = 1"
        }
        if !filter.pinboardIDs.isEmpty {
            let ids = filter.pinboardIDs.sorted()
            sql += " AND item.id IN (SELECT itemId FROM pinboard_item WHERE pinboardId IN (\(ids.map { _ in "?" }.joined(separator: ","))))"
            arguments.append(contentsOf: ids)
        }
        return (sql, arguments)
    }

    /// Distinct apps that appear in the history, most-copied first — the source for the
    /// search field's app suggestions.
    public func distinctApps() throws -> [AppUsage] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT appBundleID AS b, appName AS n, COUNT(*) AS c
                FROM item
                WHERE appBundleID IS NOT NULL AND appBundleID <> ''
                GROUP BY appBundleID
                ORDER BY c DESC, n ASC
                """).compactMap { row in
                guard let bundleID: String = row["b"] else { return nil }
                let rawName: String = row["n"] ?? bundleID
                let cleaned = cleanedName(rawName)
                let count: Int = row["c"]
                return AppUsage(bundleID: bundleID, name: cleaned.isEmpty ? bundleID : cleaned, count: count)
            }
        }
    }

    public func touch(itemID: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE item SET lastUsedAt = ? WHERE id = ?",
                arguments: [now, itemID])
        }
    }

    public func setFavorite(itemID: Int64, _ favorite: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE item SET isFavorite = ? WHERE id = ?",
                arguments: [favorite, itemID])
        }
    }

    public func delete(itemID: Int64) throws {
        try writer.write { db in
            try deleteItems(ClipItem.filter(Column("id") == itemID), in: db)
        }
    }

    public func clearHistory(keepFavorites: Bool = true) throws {
        try writer.write { db in
            let memberIDs = "SELECT DISTINCT itemId FROM pinboard_item"
            var doomed = ClipItem.filter(sql: "id NOT IN (\(memberIDs))")
            if keepFavorites {
                doomed = doomed.filter(Column("isFavorite") == false)
            }
            try deleteItems(doomed, in: db)
        }
    }

    /// Clears just one kind from the clearable history — same keep rules as
    /// `clearHistory(keepFavorites:)` (pinboard members and, when `keepFavorites`,
    /// favorites are preserved). Used by the Settings storage view's per-type "Clear".
    public func clearHistory(kind: ItemKind, keepFavorites: Bool = true) throws {
        try writer.write { db in
            let memberIDs = "SELECT DISTINCT itemId FROM pinboard_item"
            var doomed = ClipItem
                .filter(sql: "id NOT IN (\(memberIDs))")
                .filter(Column("kind") == kind.rawValue)
            if keepFavorites {
                doomed = doomed.filter(Column("isFavorite") == false)
            }
            try deleteItems(doomed, in: db)
        }
    }

    /// Per-kind item count and total `sizeBytes` over the *clearable* history: items not in
    /// any pinboard and (when `keepFavorites`) not favorited — exactly the set
    /// `clearHistory(keepFavorites:)` removes. Favorites and pinboard items are permanent
    /// (excluded from the retention prune too), so they aren't counted here. Kinds with no
    /// clearable items are omitted. Powers the Settings storage breakdown.
    public func storageBreakdown(keepFavorites: Bool = true) throws -> [StorageUsage] {
        try writer.read { db in
            var sql = """
                SELECT kind AS k, COUNT(*) AS c, COALESCE(SUM(sizeBytes), 0) AS b
                FROM item
                WHERE id NOT IN (SELECT DISTINCT itemId FROM pinboard_item)
                """
            if keepFavorites { sql += " AND isFavorite = 0" }
            sql += " GROUP BY kind"
            return try Row.fetchAll(db, sql: sql).compactMap { row in
                guard let raw: String = row["k"], let kind = ItemKind(rawValue: raw) else { return nil }
                let count: Int = row["c"]
                let bytes: Int = row["b"]
                return StorageUsage(kind: kind, count: count, bytes: bytes)
            }
        }
    }

    /// Deletes matching items and any blobs no longer referenced afterwards.
    private func deleteItems(_ request: QueryInterfaceRequest<ClipItem>, in db: Database) throws {
        let ids = try request.selectPrimaryKey(as: Int64.self).fetchAll(db)
        guard !ids.isEmpty else { return }

        var allKeys: [String] = []
        for chunk in chunked(ids, into: Self.deleteChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let keys = try String.fetchAll(db, sql: """
                SELECT DISTINCT blobKey FROM representation
                WHERE itemId IN (\(placeholders)) AND blobKey IS NOT NULL
                """, arguments: StatementArguments(chunk))
            allKeys.append(contentsOf: keys)
        }

        for chunk in chunked(ids, into: Self.deleteChunkSize) {
            try ClipItem.filter(chunk.contains(Column("id"))).deleteAll(db)
        }

        try cleanOrphanBlobs(allKeys, in: db)
    }

    private func chunked<T>(_ array: [T], into size: Int) -> [[T]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }

    /// AND-applies the filter's non-text facets using the query interface. Shared by the live
    /// observation and the synchronous `recentPage`, so both see exactly the same rows.
    /// A free-standing function (not a method) so the observation's `@Sendable` fetch closure
    /// doesn't capture `self`.
    private func applyFacets(_ filter: SearchFilter,
                             to request: QueryInterfaceRequest<ClipItem>) -> QueryInterfaceRequest<ClipItem> {
        var request = request
        if let appBundleID = filter.appBundleID {
            request = request.filter(Column("appBundleID") == appBundleID)
        }
        if let kindFacet = kindFacet(filter) {
            request = request.filter(sql: kindFacet.sql,
                                     arguments: StatementArguments(kindFacet.arguments))
        }
        if let range = filter.dateRange {
            request = request.filter(Column("lastUsedAt") >= range.start && Column("lastUsedAt") < range.end)
        }
        if filter.favoritesOnly {
            request = request.filter(Column("isFavorite") == true)
        }
        if !filter.pinboardIDs.isEmpty {
            let ids = filter.pinboardIDs.sorted()
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            request = request.filter(sql:
                "id IN (SELECT itemId FROM pinboard_item WHERE pinboardId IN (\(placeholders)))",
                arguments: StatementArguments(ids))
        }
        return request
    }

    /// One OR-ed type predicate. Image facets include native `.image` rows plus `.file`
    /// rows whose newline-separated filenames contain an image content type; other type
    /// facets retain the ordinary `kind IN (…)` behavior.
    private func kindFacet(_ filter: SearchFilter)
        -> (sql: String, arguments: [any DatabaseValueConvertible])? {
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if !filter.kinds.isEmpty {
            let names = filter.kinds.map(\.rawValue).sorted()
            clauses.append("item.kind IN (\(names.map { _ in "?" }.joined(separator: ",")))")
            arguments.append(contentsOf: names)
        }
        if filter.includesImageFiles {
            clauses.append("(item.kind = ? AND \(ImageFileDetection.sqlFunctionName)(item.plainText) = 1)")
            arguments.append(ItemKind.file.rawValue)
        }
        guard !clauses.isEmpty else { return nil }
        return ("(\(clauses.joined(separator: " OR ")))", arguments)
    }

    /// One page of shelf history: every favorite matching `filter`, plus the `limit` most
    /// recent non-favorites, favorites first.
    ///
    /// Favorites are deliberately exempt from `limit`. The shelf floats them to the front of
    /// its row, so bounding them by the same recency window would hide a favorite as soon as
    /// `limit` newer items existed, then drop it into the first position once scrolling grew
    /// the window — shifting every visible card sideways mid-scroll. Favorites are a small
    /// curated set that retention never deletes (see `RetentionPeriod`), so fetching all of
    /// them keeps the front of the row fixed for one extra indexed read.
    ///
    /// The two queries can't overlap: one asks for `isFavorite = true` and the other for
    /// `isFavorite = false`, so concatenating them never duplicates a row.
    func fetchRecentPage(_ db: Database, filter: SearchFilter, limit: Int, favoritesFirst: Bool = true) throws -> [ClipItem] {
        let base = applyFacets(filter, to: ClipItem.all())
        if !favoritesFirst {
            return try base.order(Column("lastUsedAt").desc).limit(limit).fetchAll(db)
        }
        let favorites = try base.filter(Column("isFavorite") == true)
            .order(Column("lastUsedAt").desc)
            .fetchAll(db)
        let rest = try base.filter(Column("isFavorite") == false)
            .order(Column("lastUsedAt").desc)
            .limit(limit)
            .fetchAll(db)
        return favorites + rest
    }

    /// Synchronous counterpart to `observeRecent(filter:limit:)`, for callers that want one
    /// page rather than a live feed. Same rows, same order.
    /// With `favoritesFirst: false`, favorites count toward the normal recency limit.
    public func recentPage(filter: SearchFilter, limit: Int = 100, favoritesFirst: Bool = true) throws -> [ClipItem] {
        try writer.read { db in try fetchRecentPage(db, filter: filter, limit: limit, favoritesFirst: favoritesFirst) }
    }

    public func observeRecent(kinds: Set<ItemKind>? = nil, limit: Int = 100,
                              onError: @escaping (Error) -> Void,
                              onChange: @escaping ([ClipItem]) -> Void) -> ObservationToken {
        let observation = ValueObservation.tracking { db -> [ClipItem] in
            var request = ClipItem.order(Column("lastUsedAt").desc).limit(limit)
            if let kinds {
                request = request.filter(kinds.map(\.rawValue).contains(Column("kind")))
            }
            return try request.fetchAll(db)
        }
        let cancellable = observation.start(in: writer,
                                            scheduling: .async(onQueue: .main),
                                            onError: onError,
                                            onChange: onChange)
        return ObservationToken(cancellable)
    }

    /// Live variant of `search(filter:)` for the text-empty case: observes the history
    /// with the filter's non-text facets applied, so filter-only shelf views keep updating
    /// as new items are captured. Free text (`filter.text`) is ignored here — the app layer
    /// routes text queries to the one-shot `search(filter:)` instead.
    public func observeRecent(filter: SearchFilter, limit: Int = 100, favoritesFirst: Bool = true,
                              onError: @escaping (Error) -> Void,
                              onChange: @escaping ([ClipItem]) -> Void) -> ObservationToken {
        // Built with the query interface (not `facetClauses`' raw SQL) so the observation's
        // @Sendable fetch closure captures only the Sendable `filter`/`limit`, not the
        // existential-typed argument array.
        let observation = ValueObservation.tracking { db -> [ClipItem] in
            try fetchRecentPage(db, filter: filter, limit: limit, favoritesFirst: favoritesFirst)
        }
        let cancellable = observation.start(in: writer,
                                            scheduling: .async(onQueue: .main),
                                            onError: onError,
                                            onChange: onChange)
        return ObservationToken(cancellable)
    }

    /// Replaces an image item's representation with new bytes (e.g. a rotated copy),
    /// recomputing the content hash and size and cleaning up the old blob. OCR text is
    /// cleared because it no longer matches the transformed image; it can be re-run.
    /// Mirrors `replaceContent`'s dedup-winner + orphan-blob handling.
    @discardableResult
    public func replaceImageRepresentation(itemID: Int64, data: Data, uti: String, now: Date = Date()) throws -> ClipItem {
        let hash = BlobStore.key(for: data)
        return try writer.write { db in
            guard var item = try ClipItem.fetchOne(db, key: itemID) else {
                throw DatabaseError(message: "item not found")
            }
            if var winner = try ClipItem
                .filter(Column("contentHash") == hash && Column("id") != itemID)
                .fetchOne(db) {
                winner.lastUsedAt = now
                try winner.update(db)
                try deleteItems(ClipItem.filter(Column("id") == itemID), in: db)
                return winner
            }
            let oldKeys = try String.fetchAll(db, sql:
                "SELECT DISTINCT blobKey FROM representation WHERE itemId = ? AND blobKey IS NOT NULL",
                arguments: [itemID])
            try Representation.filter(Column("itemId") == itemID).deleteAll(db)
            item.kind = .image
            item.contentHash = hash
            item.sizeBytes = data.count
            item.recognizedText = nil
            item.lastUsedAt = now
            try item.update(db)
            try insertRepresentations([CapturedRepresentation(uti: uti, data: data)], itemID: itemID, in: db)
            try cleanOrphanBlobs(oldKeys, in: db)
            return item
        }
    }

    @discardableResult
    public func replaceContent(itemID: Int64, with text: String, now: Date = Date()) throws -> ClipItem {
        let hash = BlobStore.key(for: Data(text.utf8))
        return try writer.write { db in
            guard var item = try ClipItem.fetchOne(db, key: itemID) else {
                throw DatabaseError(message: "item not found")
            }
            if var winner = try ClipItem
                .filter(Column("contentHash") == hash && Column("id") != itemID)
                .fetchOne(db) {
                winner.lastUsedAt = now
                try winner.update(db)
                try deleteItems(ClipItem.filter(Column("id") == itemID), in: db)
                return winner
            }
            let oldKeys = try String.fetchAll(db, sql:
                "SELECT DISTINCT blobKey FROM representation WHERE itemId = ? AND blobKey IS NOT NULL",
                arguments: [itemID])
            try Representation.filter(Column("itemId") == itemID).deleteAll(db)
            item.kind = ItemKind.forText(text)
            item.plainText = text
            item.linkTitle = nil
            item.contentHash = hash
            item.sizeBytes = text.utf8.count
            item.lastUsedAt = now
            try item.update(db)
            try insertRepresentations(
                [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))],
                itemID: itemID, in: db)
            try cleanOrphanBlobs(oldKeys, in: db)
            return item
        }
    }

    /// Rich-text counterpart to `replaceContent(itemID:with:)`: stores an updated
    /// `public.rtf` representation alongside the plain-text representation, instead of
    /// plain text alone. Deliberately takes pre-encoded `rtfData` rather than an
    /// `NSAttributedString` — CopyCore stays Foundation-only, so RTF encoding happens
    /// in the app layer, not here. Dedup/FTS/hash all key on `plainText`, exactly like
    /// the plain path, so a rich edit that happens to match an existing plain (or rich)
    /// item's content still dedups against it.
    @discardableResult
    public func replaceContent(itemID: Int64, rtfData: Data, plainText: String, now: Date = Date()) throws -> ClipItem {
        let hash = BlobStore.key(for: Data(plainText.utf8))
        return try writer.write { db in
            guard var item = try ClipItem.fetchOne(db, key: itemID) else {
                throw DatabaseError(message: "item not found")
            }
            if var winner = try ClipItem
                .filter(Column("contentHash") == hash && Column("id") != itemID)
                .fetchOne(db) {
                winner.lastUsedAt = now
                try winner.update(db)
                try deleteItems(ClipItem.filter(Column("id") == itemID), in: db)
                return winner
            }
            let oldKeys = try String.fetchAll(db, sql:
                "SELECT DISTINCT blobKey FROM representation WHERE itemId = ? AND blobKey IS NOT NULL",
                arguments: [itemID])
            try Representation.filter(Column("itemId") == itemID).deleteAll(db)
            item.kind = ItemKind.forText(plainText)
            item.plainText = plainText
            item.linkTitle = nil
            item.contentHash = hash
            item.sizeBytes = plainText.utf8.count
            item.lastUsedAt = now
            try item.update(db)
            try insertRepresentations(
                [CapturedRepresentation(uti: "public.rtf", data: rtfData),
                 CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(plainText.utf8))],
                itemID: itemID, in: db)
            try cleanOrphanBlobs(oldKeys, in: db)
            return item
        }
    }

    @discardableResult
    public func prune(olderThan cutoff: Date?, maxItems: Int?) throws -> Int {
        guard cutoff != nil || maxItems != nil else { return 0 }

        return try writer.write { db in
            var doomed: Set<Int64> = []

            if let cutoff {
                let oldIds = try Int64.fetchAll(db, sql: """
                    SELECT id FROM item
                    WHERE lastUsedAt < ? AND isFavorite = false
                    AND id NOT IN (SELECT DISTINCT itemId FROM pinboard_item)
                    """, arguments: [cutoff])
                doomed.formUnion(oldIds)
            }

            if let maxItems {
                let newestIds = try Int64.fetchAll(db, sql: """
                    SELECT id FROM item
                    WHERE isFavorite = false
                    AND id NOT IN (SELECT DISTINCT itemId FROM pinboard_item)
                    ORDER BY lastUsedAt DESC
                    LIMIT ?
                    """, arguments: [maxItems])
                let newestSet = Set(newestIds)

                let excessIds = try Int64.fetchAll(db, sql: """
                    SELECT id FROM item
                    WHERE isFavorite = false
                    AND id NOT IN (SELECT DISTINCT itemId FROM pinboard_item)
                    """)
                for id in excessIds {
                    if !newestSet.contains(id) {
                        doomed.insert(id)
                    }
                }
            }

            guard !doomed.isEmpty else { return 0 }

            let doomedArray = Array(doomed)
            try deleteItems(ClipItem.filter(doomedArray.contains(Column("id"))), in: db)
            return doomedArray.count
        }
    }

    public func setLinkTitle(itemID: Int64, _ title: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE item SET linkTitle = ? WHERE id = ?",
                arguments: [title, itemID])
        }
    }

    /// Sets the user-assigned label shown in place of the auto-generated title.
    /// Passing `nil` (or an empty string) clears it, reverting display to the auto title.
    public func setTitle(itemID: Int64, _ title: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE item SET title = ? WHERE id = ?",
                arguments: [title, itemID])
        }
    }

    /// Inserts a user-created plain-text item (e.g. from ⌘N), deduping by content hash
    /// like `save`: if an identical-hash item already exists, its `lastUsedAt` is bumped
    /// and it is returned unchanged (the existing title is left as-is).
    @discardableResult
    public func createTextItem(_ text: String, title: String? = nil, now: Date = Date()) throws -> ClipItem {
        let hash = BlobStore.key(for: Data(text.utf8))
        return try writer.write { db in
            if var existing = try ClipItem.filter(Column("contentHash") == hash).fetchOne(db) {
                existing.lastUsedAt = now
                try existing.update(db)
                return existing
            }
            var item = ClipItem(
                id: nil, uuid: UUID().uuidString, kind: ItemKind.forText(text),
                createdAt: now, lastUsedAt: now,
                plainText: text, linkTitle: nil,
                appBundleID: Self.userCreatedAppBundleID, appName: Self.userCreatedAppName,
                contentHash: hash,
                sizeBytes: text.utf8.count,
                isFavorite: false,
                title: title
            )
            try item.insert(db)
            try insertRepresentations(
                [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))],
                itemID: item.id!, in: db)
            return item
        }
    }

    public func setFavicon(itemID: Int64, pngData: Data) throws {
        try writer.write { db in
            // Capture old favicon blobKey before deletion
            let oldKeys = try String.fetchAll(db, sql: """
                SELECT DISTINCT blobKey FROM representation
                WHERE itemId = ? AND uti = ? AND blobKey IS NOT NULL
                """, arguments: [itemID, CopyPasteboard.faviconUTI])

            // Delete any existing favicon representation for this item
            try Representation.filter(
                Column("itemId") == itemID && Column("uti") == CopyPasteboard.faviconUTI
            ).deleteAll(db)

            // Insert the new favicon representation via insertRepresentations
            try insertRepresentations(
                [CapturedRepresentation(uti: CopyPasteboard.faviconUTI, data: pngData)],
                itemID: itemID, in: db)

            // Clean up any orphaned blobs
            try cleanOrphanBlobs(oldKeys, in: db)
        }
    }

    public func favicon(forItemID id: Int64) throws -> Data? {
        let record = try writer.read { db in
            try Representation.filter(
                Column("itemId") == id && Column("uti") == CopyPasteboard.faviconUTI
            ).fetchOne(db)
        }

        if let record {
            if let inlineData = record.inlineData {
                return inlineData
            }
            if let key = record.blobKey {
                return blobs.data(forKey: key)
            }
        }

        return nil
    }

    public func setRecognizedText(itemID: Int64, _ text: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE item SET recognizedText = ? WHERE id = ?",
                arguments: [text, itemID])
        }
    }

    public func recognizedText(forItemID id: Int64) throws -> String? {
        try writer.read { db in
            try ClipItem.filter(Column("id") == id).fetchOne(db)?.recognizedText
        }
    }

    /// Looks up a single item by its content hash — used by `ArchiveIO.importArchive`
    /// to resolve a pinboard's archived member hashes back to item ids in the target
    /// store after those items have been (re-)inserted.
    public func item(contentHash: String) throws -> ClipItem? {
        try writer.read { db in
            try ClipItem.filter(Column("contentHash") == contentHash).fetchOne(db)
        }
    }

    /// Inserts an item reconstructed from an exported archive (`ArchiveIO`), preserving
    /// its original timestamps, title, favorite flag, and recognized text so a restored
    /// history is indistinguishable from the original. Dedups by content hash like
    /// `save`/`createTextItem`: if an item with the same hash already exists, this is a
    /// no-op and returns `false` — the property that makes re-importing the same
    /// archive idempotent.
    @discardableResult
    public func importArchived(_ archived: ArchivedItem) throws -> Bool {
        guard let kind = ItemKind(rawValue: archived.kind) else {
            throw ArchiveError.unknownItemKind(archived.kind)
        }
        let reps = archived.representations.compactMap { rep -> CapturedRepresentation? in
            guard let data = Data(base64Encoded: rep.dataBase64) else { return nil }
            return CapturedRepresentation(uti: rep.uti, data: data)
        }
        return try writer.write { db in
            guard try ClipItem.filter(Column("contentHash") == archived.contentHash).fetchOne(db) == nil else {
                return false
            }
            var item = ClipItem(
                id: nil, uuid: UUID().uuidString, kind: kind,
                createdAt: archived.createdAt, lastUsedAt: archived.lastUsedAt,
                plainText: archived.plainText, linkTitle: archived.linkTitle,
                appBundleID: archived.appBundleID, appName: archived.appName,
                contentHash: archived.contentHash,
                sizeBytes: reps.reduce(0) { $0 + $1.data.count },
                isFavorite: archived.isFavorite,
                title: archived.title,
                recognizedText: archived.recognizedText
            )
            try item.insert(db)
            try insertRepresentations(reps, itemID: item.id!, in: db)
            return true
        }
    }
}

public final class ObservationToken {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() {
        cancellable.cancel()
    }

    deinit {
        cancellable.cancel()
    }
}
