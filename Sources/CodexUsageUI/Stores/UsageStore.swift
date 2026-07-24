import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var language: AppLanguage
    private let client: any CodexUsageFetching
    private let apiCostEstimator: @Sendable () -> CodexAPICostEstimate?
    private let previewOnly: Bool
    private var lastLiveUsage: CodexLiveUsage?
    private var lastAPICostEstimate: CodexAPICostEstimate?
    private var lastRefreshError: Error?
    private var isCostRefreshing = false
    private var isShuttingDown = false

    public init(
        autoRefresh: Bool = true,
        previewOnly: Bool = false,
        language: AppLanguage? = nil
    ) {
        let selectedLanguage = language ?? AppLanguage.resolveAndPersist()
        client = CodexAppServerClient()
        apiCostEstimator = { SessionAPICostEstimator.estimate() }
        self.previewOnly = previewOnly
        self.language = selectedLanguage
        snapshot = .preview(language: selectedLanguage)
        _ = autoRefresh
    }

    init(
        previewOnly: Bool = false,
        language: AppLanguage? = nil,
        client: any CodexUsageFetching,
        apiCostEstimator: @escaping @Sendable () -> CodexAPICostEstimate?
    ) {
        let selectedLanguage = language ?? AppLanguage.resolveAndPersist()
        self.client = client
        self.apiCostEstimator = apiCostEstimator
        self.previewOnly = previewOnly
        self.language = selectedLanguage
        snapshot = .preview(language: selectedLanguage)
    }

    public var menuPercent: Int {
        snapshot.periods.first?.remainingPercent ?? 0
    }

    public var statusText: String {
        if previewOnly {
            return language.demoStatus
        }
        return lastError == nil ? language.liveStatus : language.failureStatus
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: AppLanguage.storageKey)
        if let lastLiveUsage {
            snapshot = UsageSnapshot(live: lastLiveUsage, language: newLanguage)
        } else {
            snapshot = .preview(language: newLanguage)
        }
        if let lastRefreshError {
            lastError = Self.errorDescription(lastRefreshError, language: newLanguage)
        }
    }

    public func refresh() async {
        await refreshLive()
    }

    public func refreshLive() async {
        guard !previewOnly, !isShuttingDown, !Task.isCancelled else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let liveUsage = try await client.fetchUsage(
                apiCostEstimate: lastAPICostEstimate
            )
            guard !isShuttingDown, !Task.isCancelled else { return }
            let mergedUsage = liveUsage.replacingAPICostEstimate(lastAPICostEstimate)
            lastLiveUsage = mergedUsage
            snapshot = UsageSnapshot(live: mergedUsage, language: language)
            lastRefreshError = nil
            lastError = nil
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            lastRefreshError = error
            lastError = Self.errorDescription(error, language: language)
        }
    }

    public func refreshAPICost() async {
        guard !previewOnly, !isShuttingDown, !Task.isCancelled else { return }
        guard !isCostRefreshing else { return }
        isCostRefreshing = true
        defer { isCostRefreshing = false }

        let estimate = await cancellableAPICostEstimate()
        guard
            let estimate,
            !isShuttingDown,
            !Task.isCancelled
        else { return }

        lastAPICostEstimate = estimate
        if let liveUsage = lastLiveUsage?.replacingAPICostEstimate(estimate) {
            lastLiveUsage = liveUsage
            snapshot = UsageSnapshot(live: liveUsage, language: language)
        } else {
            snapshot.apiCostEstimate = APICostEstimateSnapshot(
                sevenDayUSD: estimate.sevenDayUSD,
                lifetimeUSD: estimate.lifetimeUSD,
                coveragePercent: estimate.observedTokens > 0
                    ? Int((Double(estimate.pricedTokens)
                        / Double(estimate.observedTokens) * 100).rounded())
                    : 0,
                modelNames: estimate.modelNames
            )
        }
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        await client.shutdown()
    }

    private func cancellableAPICostEstimate() async -> CodexAPICostEstimate? {
        let bridge = APICostEstimateCancellationBridge()
        let estimator = apiCostEstimator
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard bridge.install(continuation) else { return }
                _ = Task.detached(priority: .utility) {
                    bridge.finish(estimator())
                }
            }
        } onCancel: {
            bridge.cancel()
        }
    }

    private static func errorDescription(_ error: Error, language: AppLanguage) -> String {
        if let clientError = error as? CodexUsageClientError {
            return clientError.description(language: language)
        }
        return error.localizedDescription
    }
}

private final class APICostEstimateCancellationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodexAPICostEstimate?, Never>?
    private var isCancelled = false

    func install(
        _ continuation: CheckedContinuation<CodexAPICostEstimate?, Never>
    ) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ estimate: CodexAPICostEstimate?) {
        lock.lock()
        guard !isCancelled, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: estimate)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
