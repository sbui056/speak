import Synchronization
@testable import SpeakCore

/// Permissions the test grants and revokes by hand. Only the microphone has a
/// system prompt; the others send the user to System Settings.
public final class FakePermissionChecker: PermissionChecker {
    private let state = Mutex<(granted: Set<Permission>, opened: [Permission])>(([], []))

    public init(granted: Set<Permission> = Set(Permission.allCases)) {
        state.withLock { $0.granted = granted }
    }

    public func set(_ permission: Permission, granted: Bool) {
        state.withLock { s in
            if granted { s.granted.insert(permission) } else { s.granted.remove(permission) }
        }
    }

    /// Every Settings pane opened, in order.
    public var opened: [Permission] { state.withLock { $0.opened } }

    public func isGranted(_ permission: Permission) async -> Bool { state.withLock { $0.granted.contains(permission) } }

    public func request(_ permission: Permission) async -> Bool { permission == .microphone }

    public func openSettings(_ permission: Permission) async { state.withLock { $0.opened.append(permission) } }
}
