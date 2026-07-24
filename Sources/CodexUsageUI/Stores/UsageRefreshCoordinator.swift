import Foundation

@MainActor
protocol UsageRefreshTarget: AnyObject {
    func refreshLive() async
    func refreshAPICost() async
    func shutdown() async
}

extension UsageStore: UsageRefreshTarget {}

@MainActor
public final class UsageRefreshCoordinator {
    private let target: any UsageRefreshTarget
    private let liveRefreshInterval: Duration
    private let costRefreshInterval: Duration
    private var liveLoop: Task<Void, Never>?
    private var costLoop: Task<Void, Never>?
    private var isStopping = false

    public init(
        store: UsageStore,
        liveRefreshInterval: Duration = .seconds(60),
        costRefreshInterval: Duration = .seconds(15 * 60)
    ) {
        target = store
        self.liveRefreshInterval = liveRefreshInterval
        self.costRefreshInterval = costRefreshInterval
    }

    init(
        target: any UsageRefreshTarget,
        liveRefreshInterval: Duration,
        costRefreshInterval: Duration
    ) {
        self.target = target
        self.liveRefreshInterval = liveRefreshInterval
        self.costRefreshInterval = costRefreshInterval
    }

    public func start() {
        guard liveLoop == nil, costLoop == nil, !isStopping else { return }

        liveLoop = Task { [weak self] in
            guard let self else { return }
            await target.refreshLive()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: liveRefreshInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await target.refreshLive()
            }
        }

        costLoop = Task { [weak self] in
            guard let self else { return }
            await target.refreshAPICost()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: costRefreshInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await target.refreshAPICost()
            }
        }
    }

    public func refreshNow(includeCost: Bool = true) async {
        guard !isStopping else { return }
        await target.refreshLive()
        if includeCost {
            await target.refreshAPICost()
        }
    }

    public func stop() async {
        guard !isStopping else { return }
        isStopping = true

        let liveTask = liveLoop
        let costTask = costLoop
        liveTask?.cancel()
        costTask?.cancel()

        // Interrupt the app-server request before waiting for the loop tasks.
        // Both loops then observe cancellation and cannot schedule a tail run.
        await target.shutdown()
        await liveTask?.value
        await costTask?.value

        liveLoop = nil
        costLoop = nil
    }
}
