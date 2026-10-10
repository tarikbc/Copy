import Foundation
import GRDB

public final class DatabaseManager {
    public let writer: any DatabaseWriter
    public let blobsDirectory: URL

    public static func makeDefault() throws -> DatabaseManager {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Copy", isDirectory: true)
        return try DatabaseManager(directory: appSupport)
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        blobsDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                ImageFileDetection.sqlFunctionName,
                argumentCount: 1,
                pure: true
            ) { values in
                guard let filenames = String.fromDatabaseValue(values[0]) else { return false }
                return ImageFileDetection.containsImageFile(in: filenames)
            })
        }
        writer = try DatabasePool(
            path: directory.appendingPathComponent("copy.sqlite").path,
            configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull().indexed()
                t.column("plainText", .text)
                t.column("linkTitle", .text)
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("contentHash", .text).notNull().unique()
                t.column("sizeBytes", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "representation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("item", onDelete: .cascade).notNull()
                t.column("uti", .text).notNull()
                t.column("inlineData", .blob)
                t.column("blobKey", .text)
            }
            try db.create(table: "pinboard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("tint", .text).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "pinboard_item") { t in
                t.belongsTo("pinboard", onDelete: .cascade).notNull()
                t.belongsTo("item", onDelete: .cascade).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.primaryKey(["pinboardId", "itemId"])
            }
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61()
                t.column("plainText")
                t.column("appName")
                t.column("linkTitle")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "item") { t in
                t.add(column: "title", .text)
                t.add(column: "recognizedText", .text)
            }

            // Rebuild item_fts to also index title and recognizedText. FTS5 external-content
            // tables can't gain columns via ALTER, so drop the synchronized table and its
            // sync triggers, then recreate: `synchronize(withTable:)` re-registers the
            // triggers and GRDB issues an FTS5 'rebuild', repopulating the index from the
            // existing item rows.
            try db.dropFTS5SynchronizationTriggers(forTable: "item_fts")
            try db.drop(table: "item_fts")
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61()
                t.column("plainText")
                t.column("appName")
                t.column("linkTitle")
                t.column("title")
                t.column("recognizedText")
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "pinboard") { t in
                t.add(column: "emoji", .text)
            }
        }
        migrator.registerMigration("v4") { db in
            // NULL = not checked yet; `ItemStore.pruneSecrets` fills it in.
            try db.alter(table: "item") { t in
                t.add(column: "containsSecret", .boolean)
            }
        }
        return migrator
    }
}
