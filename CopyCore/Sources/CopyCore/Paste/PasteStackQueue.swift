import Foundation

public struct PasteStackQueue: Equatable, Sendable {
    public private(set) var itemUUIDs: [String] = []
    private var temporaryEntries: [String: PasteStackTextEntry] = [:]
    public var isLIFO = false

    public init() {}

    public mutating func enqueueTexts(_ texts: [String]) {
        for text in texts {
            let entry = PasteStackTextEntry(text: text)
            temporaryEntries[entry.uuid] = entry
            itemUUIDs.append(entry.uuid)
        }
    }

    public func temporaryEntry(for uuid: String) -> PasteStackTextEntry? {
        temporaryEntries[uuid]
    }

    @discardableResult
    public mutating func updateTemporaryEntry(_ uuid: String, text: String, rtfData: Data?) -> Bool {
        guard var entry = temporaryEntries[uuid] else { return false }
        entry.text = text
        entry.rtfData = rtfData
        temporaryEntries[uuid] = entry
        return true
    }

    public mutating func enqueue(_ uuid: String) {
        if let index = itemUUIDs.firstIndex(of: uuid) {
            itemUUIDs.remove(at: index)
        }
        itemUUIDs.append(uuid)
    }

    public mutating func remove(_ uuid: String) {
        itemUUIDs.removeAll { $0 == uuid }
        temporaryEntries.removeValue(forKey: uuid)
    }

    public mutating func move(from: Int, to: Int) {
        guard from >= 0, from < itemUUIDs.count,
              to >= 0, to < itemUUIDs.count else {
            return
        }
        let item = itemUUIDs.remove(at: from)
        itemUUIDs.insert(item, at: to)
    }

    public mutating func clear() {
        itemUUIDs.removeAll()
        temporaryEntries.removeAll()
    }

    public var next: String? {
        isLIFO ? itemUUIDs.last : itemUUIDs.first
    }

    @discardableResult
    public mutating func advance() -> String? {
        guard !itemUUIDs.isEmpty else { return nil }
        let index = isLIFO ? itemUUIDs.count - 1 : 0
        let uuid = itemUUIDs.remove(at: index)
        temporaryEntries.removeValue(forKey: uuid)
        return uuid
    }

    public var isEmpty: Bool {
        itemUUIDs.isEmpty
    }

    public var count: Int {
        itemUUIDs.count
    }
}
