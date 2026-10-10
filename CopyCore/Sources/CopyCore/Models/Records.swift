import Foundation
import GRDB

public struct ClipItem: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "item"

    public var id: Int64?
    public var uuid: String
    public var kind: ItemKind
    public var createdAt: Date
    public var lastUsedAt: Date
    public var plainText: String?
    public var linkTitle: String?
    public var appBundleID: String?
    public var appName: String?
    public var contentHash: String
    public var sizeBytes: Int
    public var isFavorite: Bool
    public var title: String?
    public var recognizedText: String?
    /// Whether the text holds a secret (`SecretDetector`). `nil` until
    /// `ItemStore.pruneSecrets` has checked it, and again after an edit.
    public var containsSecret: Bool?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Representation: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "representation"

    public var id: Int64?
    public var itemId: Int64
    public var uti: String
    public var inlineData: Data?
    public var blobKey: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Pinboard: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pinboard"

    public var id: Int64?
    public var name: String
    public var symbol: String
    public var tint: String
    public var emoji: String?
    public var sortIndex: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
