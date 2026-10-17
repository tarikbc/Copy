import Foundation

/// In-memory content owned by the queue. It never enters ItemStore or clipboard history.
public struct PasteStackTextEntry: Equatable, Sendable {
    public let uuid: String
    public var text: String
    public var rtfData: Data?
    private let createdAt: Date

    init(text: String) {
        uuid = UUID().uuidString
        self.text = text
        createdAt = Date()
    }

    public var item: ClipItem {
        ClipItem(id: nil, uuid: uuid, kind: rtfData == nil ? .text : .richText,
                 createdAt: createdAt, lastUsedAt: createdAt, plainText: text,
                 linkTitle: nil, appBundleID: nil, appName: nil, contentHash: "",
                 sizeBytes: text.utf8.count, isFavorite: false, title: nil, recognizedText: nil)
    }

    public var representations: [CapturedRepresentation] {
        var result = [CapturedRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))]
        if let rtfData { result.append(CapturedRepresentation(uti: "public.rtf", data: rtfData)) }
        return result
    }
}
