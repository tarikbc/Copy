import Foundation

public struct PasteStackBatchRequest: Decodable, Equatable, Sendable {
    public let version: Int
    public let items: [String]
    public let expiresAt: TimeInterval

    public func isExpired(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        expiresAt <= now
    }

    public func monotonicDeadline(wallTime: TimeInterval = Date().timeIntervalSince1970,
                                  uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        uptime + max(0, expiresAt - wallTime)
    }

    public static func decode(_ data: Data, now: TimeInterval = Date().timeIntervalSince1970) -> PasteStackBatchRequest? {
        guard data.count <= 6_295_552,
              let request = try? JSONDecoder().decode(Self.self, from: data),
              request.version == 1, request.expiresAt.isFinite, now.isFinite,
              request.expiresAt <= now + 300 else { return nil }
        var queue = PasteStackQueue()
        return queue.replaceWithBatch(request.items) ? request : nil
    }
}
