import AppKit
import Network

/// One owner for system observers; dependency injection allows notification
/// routing to be tested without sleeping the entire workstation.
@MainActor
public final class UsageLifecycleObserver {
    private let workspaceCenter: NotificationCenter
    private let powerCenter: NotificationCenter
    private var workspaceTokens: [NSObjectProtocol] = []
    private var powerToken: NSObjectProtocol?
    private var network: NetworkRecoveryWatcher?

    public convenience init(coordinator: UsageRefreshCoordinator) {
        self.init(coordinator: coordinator, workspaceCenter: NSWorkspace.shared.notificationCenter,
                  powerCenter: .default, lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                  monitorNetwork: true)
    }

    init(coordinator: UsageRefreshCoordinator, workspaceCenter: NotificationCenter,
         powerCenter: NotificationCenter, lowPower: @escaping @MainActor @Sendable () -> Bool,
         monitorNetwork: Bool = false) {
        self.workspaceCenter = workspaceCenter
        self.powerCenter = powerCenter
        coordinator.setLowPower(lowPower())
        workspaceTokens = [
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak coordinator] _ in
                Task { @MainActor in await coordinator?.setSleeping(true) }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak coordinator] _ in
                Task { @MainActor in await coordinator?.setSleeping(false) }
            }
        ]
        powerToken = powerCenter.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.setLowPower(lowPower()) }
        }
        if monitorNetwork {
            network = NetworkRecoveryWatcher { [weak coordinator] in
                Task { @MainActor in coordinator?.connectionRestored() }
            }
        }
    }

    public func stop() {
        workspaceTokens.forEach { workspaceCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        if let powerToken { powerCenter.removeObserver(powerToken) }
        powerToken = nil
        network?.stop()
        network = nil
    }
}

struct NetworkRecoveryState {
    private var previous: Bool?
    mutating func update(reachable: Bool) -> Bool {
        defer { previous = reachable }
        return previous == false && reachable
    }
}

private final class NetworkRecoveryWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var state = NetworkRecoveryState()
    private var stopped = false
    init(recovered: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            let shouldNotify = !stopped && state.update(reachable: path.status == .satisfied)
            lock.unlock()
            if shouldNotify { recovered() }
        }
        monitor.start(queue: DispatchQueue(label: "com.kevinchen.CodexUsageMonitor.network", qos: .utility))
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        monitor.cancel()
    }
    deinit { stop() }
}
