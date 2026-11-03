import Foundation

@MainActor
protocol UsageRefreshTarget: AnyObject {
    var liveRefreshSucceeded: Bool { get }
    func refreshLive() async
    func refreshAPICost() async
    func shutdown() async
    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?)
}

extension UsageRefreshTarget {
    var liveRefreshSucceeded: Bool { true }
    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?) {}
}

extension UsageStore: UsageRefreshTarget {
    var liveRefreshSucceeded: Bool { hasCurrentQuota }
    func setQuotaChangeHandler(_ handler: (@Sendable () -> Void)?) { clientQuotaChangeHandler(handler) }
}

enum RefreshPolicy {
    static func interval(base: Duration, failures: Int, lowPower: Bool) -> Duration {
        min(base * (1 << min(4, max(0, failures))) * (lowPower ? 2 : 1), .seconds(1800))
    }
}

@MainActor
public final class UsageRefreshCoordinator {
    private let target: any UsageRefreshTarget
    private let liveRefreshInterval: Duration
    private let costRefreshInterval: Duration
    private let eventDelay: Duration
    private let costEventDelay: Duration
    private var liveLoop: Task<Void, Never>?
    private var costLoop: Task<Void, Never>?
    private var quotaEventTask: Task<Void, Never>?
    private var costEventTask: Task<Void, Never>?
    private var fileWatcher: SessionChangeWatcher?
    private var costGeneration = 0
    private var isStopping = false
    private var isSleeping = false
    private var isLowPower = false
    private var failures = 0
    private var scheduleEpoch = 0
    private var suspensionDrain: Task<Void, Never>?
    private let watchFiles: Bool

    public convenience init(store: UsageStore, liveRefreshInterval: Duration = .seconds(60),
                            costRefreshInterval: Duration = .seconds(15 * 60)) {
        self.init(target: store, liveRefreshInterval: liveRefreshInterval,
                  costRefreshInterval: costRefreshInterval, watchFiles: !store.isDemo)
    }

    init(target: any UsageRefreshTarget, liveRefreshInterval: Duration, costRefreshInterval: Duration,
         eventDelay: Duration = .seconds(1), costEventDelay: Duration = .seconds(30), watchFiles: Bool = false) {
        self.target = target
        self.liveRefreshInterval = liveRefreshInterval
        self.costRefreshInterval = costRefreshInterval
        self.eventDelay = eventDelay
        self.costEventDelay = costEventDelay
        self.watchFiles = watchFiles
    }

    public func start() {
        guard liveLoop == nil, costLoop == nil, suspensionDrain == nil, !isStopping, !isSleeping else { return }
        target.setQuotaChangeHandler { [weak self] in Task { @MainActor in self?.quotaChanged() } }
        if watchFiles && fileWatcher == nil {
            fileWatcher = SessionChangeWatcher { [weak self] in Task { @MainActor in self?.sessionFilesChanged() } }
        }
        liveLoop = Task { [weak self] in
            guard let self else { return }
            await runLiveLoop()
        }
        costLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await target.refreshAPICost()
                do { try await Task.sleep(for: costRefreshInterval * (isLowPower ? 2 : 1)) }
                catch { break }
            }
        }
    }

    private func refreshQuota() async {
        guard !isStopping, !isSleeping, !Task.isCancelled else { return }
        await target.refreshLive()
        failures = target.liveRefreshSucceeded ? 0 : min(failures + 1, 4)
    }

    private func runLiveLoop() async {
        while !Task.isCancelled, !isSleeping, !isStopping {
            await refreshQuota()
            do { try await Task.sleep(for: RefreshPolicy.interval(
                base: liveRefreshInterval, failures: failures, lowPower: isLowPower)) }
            catch { break }
        }
    }

    /// A recovered network path is a reason to retry, not proof that the quota
    /// endpoint is reachable. Drain an old request before replacing its timer.
    public func connectionRestored() {
        guard !isSleeping, !isStopping, let previous = liveLoop else { return }
        UsageTelemetry.lifecycle.info("Network path recovered; restarting quota polling")
        failures = 0
        previous.cancel()
        liveLoop = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled, !isSleeping, !isStopping else { return }
            await runLiveLoop()
        }
    }

    func quotaChanged() {
        guard quotaEventTask == nil, !isSleeping, !isStopping else { return }
        let epoch = scheduleEpoch
        quotaEventTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == scheduleEpoch { quotaEventTask = nil } }
            do { try await Task.sleep(for: eventDelay) } catch { return }
            await refreshQuota()
        }
    }

    func sessionFilesChanged() {
        costGeneration += 1
        guard costEventTask == nil, !isSleeping, !isStopping else { return }
        let epoch = scheduleEpoch
        costEventTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == scheduleEpoch { costEventTask = nil } }
            repeat {
                // Bounded coalescing: continuously busy chats cannot starve it.
                do { try await Task.sleep(for: costEventDelay * (isLowPower ? 4 : 1)) } catch { return }
                guard !isSleeping, !isStopping, !Task.isCancelled else { return }
                let generation = costGeneration
                await target.refreshAPICost()
                if generation == costGeneration { break }
            } while !Task.isCancelled
        }
    }

    public func setLowPower(_ enabled: Bool) {
        isLowPower = enabled
        UsageTelemetry.lifecycle.info("Low power enabled=\(enabled, privacy: .public)")
    }

    public func setSleeping(_ sleeping: Bool) async {
        guard isSleeping != sleeping, !isStopping else { return }
        UsageTelemetry.lifecycle.info("Sleep state sleeping=\(sleeping, privacy: .public)")
        isSleeping = sleeping
        if sleeping {
            let tasks = cancelScheduledWork()
            let previous = suspensionDrain
            let drain = Task {
                await previous?.value
                for task in tasks { await task.value }
            }
            suspensionDrain = drain
            await drain.value
        } else {
            // A wake event can arrive while cancelled work is still unwinding.
            // Drain it before starting new loops; old callbacks cannot clear
            // the new event-task handles because they carry a schedule epoch.
            await suspensionDrain?.value
            guard !isSleeping, !isStopping else { return }
            suspensionDrain = nil
            failures = 0
            start()
        }
    }

    public func refreshNow(includeCost: Bool = true) async {
        guard !isStopping, !isSleeping else { return }
        await refreshQuota()
        if includeCost && !Task.isCancelled { await target.refreshAPICost() }
    }

    private func cancelScheduledWork() -> [Task<Void, Never>] {
        scheduleEpoch += 1
        let tasks = [liveLoop, costLoop, quotaEventTask, costEventTask].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        liveLoop = nil; costLoop = nil; quotaEventTask = nil; costEventTask = nil
        return tasks
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true
        target.setQuotaChangeHandler(nil)
        fileWatcher?.stop()
        fileWatcher = nil
        let tasks = cancelScheduledWork()
        await target.shutdown()
        for task in tasks { await task.value }
        await suspensionDrain?.value
        suspensionDrain = nil
    }
}
