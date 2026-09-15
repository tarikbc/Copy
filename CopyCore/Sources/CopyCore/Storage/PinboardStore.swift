import Foundation
import GRDB

public struct PinboardStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func create(name: String, symbol: String, emoji: String? = nil, tint: String = "") throws -> Pinboard {
        try writer.write { db in
            let nextIndex = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM pinboard") ?? 0) + 1
            var board = Pinboard(id: nil, name: name, symbol: symbol, tint: tint, emoji: emoji, sortIndex: nextIndex)
            try board.insert(db)
            return board
        }
    }

    public func rename(id: Int64, to name: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE pinboard SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func setSymbol(id: Int64, _ symbol: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE pinboard SET symbol = ? WHERE id = ?", arguments: [symbol, id])
        }
    }

    public func setEmoji(id: Int64, _ emoji: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE pinboard SET emoji = ? WHERE id = ?", arguments: [emoji, id])
        }
    }

    public func setTint(id: Int64, _ tint: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE pinboard SET tint = ? WHERE id = ?", arguments: [tint, id])
        }
    }

    public func delete(id: Int64) throws {
        try writer.write { db in
            _ = try Pinboard.deleteOne(db, key: id)
        }
    }

    public func all() throws -> [Pinboard] {
        try writer.read { db in
            try Self.fetchAll(db)
        }
    }

    /// Moves one pinboard before or after another and persists the complete tab order.
    /// History is not a database pinboard, so it can never enter this operation and
    /// remains fixed at the front of the shelf.
    @discardableResult
    public func move(id: Int64, relativeTo targetID: Int64, placeAfterTarget: Bool) throws -> [Pinboard] {
        try writer.write { db in
            var ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM pinboard ORDER BY sortIndex ASC, id ASC
                """)
            guard id != targetID,
                  let sourceIndex = ids.firstIndex(of: id),
                  let targetIndex = ids.firstIndex(of: targetID) else {
                return try Self.fetchAll(db)
            }

            ids.remove(at: sourceIndex)
            var insertionIndex = targetIndex + (placeAfterTarget ? 1 : 0)
            if sourceIndex < insertionIndex { insertionIndex -= 1 }
            insertionIndex = min(max(0, insertionIndex), ids.count)
            ids.insert(id, at: insertionIndex)

            for (sortIndex, pinboardID) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE pinboard SET sortIndex = ? WHERE id = ?",
                    arguments: [sortIndex, pinboardID]
                )
            }
            return try Self.fetchAll(db)
        }
    }

    public func add(itemID: Int64, to pinboardID: Int64) throws {
        try writer.write { db in
            let exists = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM pinboard_item WHERE pinboardId = ? AND itemId = ?",
                arguments: [pinboardID, itemID]) ?? 0
            guard exists == 0 else { return }
            let nextIndex = (try Int.fetchOne(db, sql:
                "SELECT MAX(sortIndex) FROM pinboard_item WHERE pinboardId = ?",
                arguments: [pinboardID]) ?? 0) + 1
            try db.execute(sql:
                "INSERT INTO pinboard_item (pinboardId, itemId, sortIndex) VALUES (?, ?, ?)",
                arguments: [pinboardID, itemID, nextIndex])
        }
    }

    public func remove(itemID: Int64, from pinboardID: Int64) throws {
        try writer.write { db in
            try db.execute(sql:
                "DELETE FROM pinboard_item WHERE pinboardId = ? AND itemId = ?",
                arguments: [pinboardID, itemID])
        }
    }

    public func items(in pinboardID: Int64, limit: Int = 200) throws -> [ClipItem] {
        try writer.read { db in
            try Self.fetchItems(in: pinboardID, limit: limit, db: db)
        }
    }

    public func pinboardIDs(forItemID itemID: Int64) throws -> Set<Int64> {
        try writer.read { db in
            Set(try Int64.fetchAll(db, sql:
                "SELECT pinboardId FROM pinboard_item WHERE itemId = ?", arguments: [itemID]))
        }
    }

    public func observeAll(onError: @escaping (Error) -> Void,
                           onChange: @escaping ([Pinboard]) -> Void) -> ObservationToken {
        let observation = ValueObservation.tracking { db in
            try Self.fetchAll(db)
        }
        return ObservationToken(observation.start(in: writer,
                                                  scheduling: .async(onQueue: .main),
                                                  onError: onError, onChange: onChange))
    }

    public func observeItems(in pinboardID: Int64, limit: Int = 200,
                             onError: @escaping (Error) -> Void,
                             onChange: @escaping ([ClipItem]) -> Void) -> ObservationToken {
        let observation = ValueObservation.tracking { db in
            try Self.fetchItems(in: pinboardID, limit: limit, db: db)
        }
        return ObservationToken(observation.start(in: writer,
                                                  scheduling: .async(onQueue: .main),
                                                  onError: onError, onChange: onChange))
    }

    private static func fetchItems(in pinboardID: Int64, limit: Int, db: Database) throws -> [ClipItem] {
        try ClipItem.fetchAll(db, sql: """
            SELECT item.* FROM item
            JOIN pinboard_item ON pinboard_item.itemId = item.id
            WHERE pinboard_item.pinboardId = ?
            ORDER BY pinboard_item.sortIndex DESC
            LIMIT ?
            """, arguments: [pinboardID, limit])
    }

    private static func fetchAll(_ db: Database) throws -> [Pinboard] {
        try Pinboard
            .order(Column("sortIndex").asc, Column("id").asc)
            .fetchAll(db)
    }
}
