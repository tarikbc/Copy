import Foundation

public struct PasteStackCaller: Equatable, Sendable {
    public var bundleID: String
    public var canonicalPath: String
    public var signingID: String?
    public var certificateSHA256: String?

    public init(bundleID: String, canonicalPath: String, signingID: String? = nil, certificateSHA256: String? = nil) {
        self.bundleID = bundleID
        self.canonicalPath = canonicalPath
        self.signingID = signingID
        self.certificateSHA256 = certificateSHA256
    }
}

public enum PasteStackPermission: Codable, Hashable, Sendable {
    case signed(bundleID: String, signingID: String, certificateSHA256: String)
    case developer(bundleID: String, canonicalPath: String)

    public func permits(_ caller: PasteStackCaller) -> Bool {
        switch self {
        case let .signed(bundleID, signingID, certificateSHA256):
            return !bundleID.isEmpty && !signingID.isEmpty && !certificateSHA256.isEmpty
                && caller.bundleID == bundleID && caller.signingID == signingID
                && caller.certificateSHA256 == certificateSHA256
        case let .developer(bundleID, canonicalPath):
            return !bundleID.isEmpty && !canonicalPath.isEmpty
                && caller.bundleID == bundleID && caller.canonicalPath == canonicalPath
        }
    }
}
