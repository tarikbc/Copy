import Foundation

public final class PasteStackExternalAccess {
    public struct State: Codable {
        public var enabled: Bool
        public var permissions: [PasteStackPermission]

        public init(enabled: Bool, permissions: [PasteStackPermission] = []) {
            self.enabled = enabled
            self.permissions = permissions
        }
    }

    private var enabled: Bool
    private let read: () -> State?
    private let write: (State) -> Bool

    public init(enabled: Bool, read: @escaping () -> State?, write: @escaping (State) -> Bool) {
        self.enabled = enabled
        self.read = read
        self.write = write
    }

    public func permitsRequests() -> Bool {
        enabled && (read()?.enabled == true)
    }

    public func enable() -> Bool {
        var state = read() ?? State(enabled: false)
        state.enabled = true
        guard write(state) else { return false }
        enabled = true
        return true
    }

    public func disable() -> Bool {
        guard var state = read() else { return false }
        state.enabled = false
        guard write(state) else { return false }
        enabled = false
        return true
    }

    public func permissions() -> [PasteStackPermission] {
        guard enabled, let state = read(), state.enabled else { return [] }
        return state.permissions
    }

    public func setPermissions(_ permissions: [PasteStackPermission]) -> Bool {
        guard enabled, var state = read(), state.enabled else { return false }
        state.permissions = permissions
        return write(state)
    }
}
