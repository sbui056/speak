import Observation

// MARK: Permissions

public enum Permission: CaseIterable, Sendable {
    case microphone
    case inputMonitoring
    case accessibility

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    /// What the permission is for, in the user's terms.
    public var purpose: String {
        switch self {
        case .microphone: "Hear what you dictate"
        case .inputMonitoring: "Notice when you hold the shortcut key"
        case .accessibility: "Type the text where your cursor is"
        }
    }
}

public protocol PermissionChecker: Sendable {
    func isGranted(_ permission: Permission) async -> Bool
    /// Shows the system prompt where one exists. Returns whether one did.
    @discardableResult func request(_ permission: Permission) async -> Bool
    /// Opens the exact System Settings pane.
    func openSettings(_ permission: Permission) async
}

// MARK: Model

/// The three permissions, kept current: checked at launch, when the app becomes
/// active, and every 2 s while any is missing.
@MainActor
@Observable
public final class PermissionsModel {
    public private(set) var granted: [Permission: Bool] = [:]
    /// Input Monitoring was granted after launch; the event tap only works after a relaunch.
    public private(set) var needsRelaunch = false
    public var allGranted: Bool { Permission.allCases.allSatisfy { granted[$0] == true } }
    public var missing: [Permission] { Permission.allCases.filter { granted[$0] != true } }

    @ObservationIgnored private let checker: any PermissionChecker
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var inputMonitoringAtLaunch: Bool?
    /// Called whenever a permission changes.
    @ObservationIgnored public var onChange: ((Permission, Bool) -> Void)?

    public static let pollInterval: Duration = .seconds(2)

    public init(checker: any PermissionChecker, clock: any Clock<Duration>) {
        self.checker = checker
        self.clock = clock
    }

    public func refresh() async {
        // Read everything first, then apply in one step: an await between updates
        // would let observers see "all granted" before `needsRelaunch` is set.
        var latest: [Permission: Bool] = [:]
        for permission in Permission.allCases {
            latest[permission] = await checker.isGranted(permission)
        }
        let changed = Permission.allCases.filter { granted[$0] != latest[$0] }
        granted = latest
        if inputMonitoringAtLaunch == nil { inputMonitoringAtLaunch = granted[.inputMonitoring] }
        if inputMonitoringAtLaunch == false, granted[.inputMonitoring] == true { needsRelaunch = true }
        for permission in changed { onChange?(permission, latest[permission] == true) }
        pollWhileMissing()
    }

    public func request(_ permission: Permission) async {
        if await !checker.request(permission) { await checker.openSettings(permission) }
        await refresh()
    }

    public func openSettings(_ permission: Permission) async {
        await checker.openSettings(permission)
    }

    private func pollWhileMissing() {
        guard !allGranted else {
            poll?.cancel()
            poll = nil
            return
        }
        guard poll == nil else { return }
        let clock = self.clock
        let deadline = Deadline(after: Self.pollInterval, on: clock)
        poll = Task { [weak self] in
            guard await deadline.reached(), let self else { return }
            self.poll = nil
            await self.refresh() // Schedules the next check if still needed.
        }
    }
}
