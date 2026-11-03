import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var language: AppLanguage
    @Published public var panelMaximumHeight: CGFloat = UsagePanelMetrics.height
    @Published private(set) var sourceHealth: [UsageSource: SourceHealth] = [:]
    @Published private(set) var costHealth = CostIngestionHealth()
    @Published public var selectedQuotaID: String {
        didSet { defaults.set(selectedQuotaID, forKey: "display.menuQuotaID") }
    }
    private let defaults: UserDefaults
    private let client: any CodexUsageFetching
    private let apiCostEstimator: @Sendable () -> CostScanResult
    private let previewOnly: Bool
    private var lastLiveUsage: CodexLiveUsage?
    private var lastAPICostEstimate: CodexAPICostEstimate?
    private var lastRefreshError: Error?
    private var isCostRefreshing = false
    private var isShuttingDown = false
    public var isDemo: Bool { previewOnly }

    func clientQuotaChangeHandler(_ handler: (@Sendable () -> Void)?) {
        client.setQuotaChangeHandler(handler)
    }

    public init(
        autoRefresh: Bool = true,
        previewOnly: Bool = false,
        language: AppLanguage? = nil,
        defaults: UserDefaults = .standard
    ) {
        let selectedLanguage = language ?? AppLanguage.resolveAndPersist(defaults: defaults)
        self.defaults = defaults
        selectedQuotaID = defaults.string(forKey: "display.menuQuotaID") ?? ""
        client = CodexAppServerClient()
        apiCostEstimator = { SessionAPICostEstimator.scan() }
        self.previewOnly = previewOnly
        self.language = selectedLanguage
        snapshot = previewOnly ? .preview(language: selectedLanguage) : .empty(language: selectedLanguage)
        sourceHealth = Dictionary(uniqueKeysWithValues: UsageSource.allCases.map {
            ($0, previewOnly ? SourceHealth(state: .demo) : .loading)
        })
        _ = autoRefresh
    }

    init(
        previewOnly: Bool = false,
        language: AppLanguage? = nil,
        client: any CodexUsageFetching,
        apiCostEstimator: @escaping @Sendable () -> CodexAPICostEstimate?,
        defaults: UserDefaults = .standard
    ) {
        let selectedLanguage = language ?? AppLanguage.resolveAndPersist(defaults: defaults)
        self.defaults = defaults
        selectedQuotaID = defaults.string(forKey: "display.menuQuotaID") ?? ""
        self.client = client
        self.apiCostEstimator = { CostScanResult(estimate: apiCostEstimator(), health: CostIngestionHealth()) }
        self.previewOnly = previewOnly
        self.language = selectedLanguage
        snapshot = previewOnly ? .preview(language: selectedLanguage) : .empty(language: selectedLanguage)
        sourceHealth = Dictionary(uniqueKeysWithValues: UsageSource.allCases.map {
            ($0, previewOnly ? SourceHealth(state: .demo) : .loading)
        })
    }

    public var menuPercent: Int? {
        (snapshot.periods.first { $0.id == selectedQuotaID } ?? snapshot.periods.first)?.remainingPercent
    }

    public var menuText: String {
        guard let menuPercent else { return "—" }
        return "\(menuPercent)%" + (sourceHealth[.limits]?.state == .stale ? " !" : "")
    }

    var hasCurrentQuota: Bool {
        sourceHealth[.limits]?.state == .live || previewOnly
    }

    public var statusText: String {
        if previewOnly {
            return language.demoStatus
        }
        switch sourceHealth[.limits]?.state {
        case .loading, nil:
            return language == .english ? "Connecting to Codex…" : "正在连接 Codex…"
        case .stale:
            return language == .english ? "Quota stale · Retry available" : "额度为旧数据 · 可重试"
        case .unavailable:
            return language.failureStatus
        default:
            if !costHealth.issues.isEmpty || sourceHealth.values.contains(where: { $0.state == .stale || $0.state == .unavailable }) {
                return language == .english ? "Connected · Partial data" : "已连接 · 部分数据不可用"
            }
            return language.liveStatus
        }
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        let preservedCost = snapshot.apiCostEstimate
        language = newLanguage
        defaults.set(newLanguage.rawValue, forKey: AppLanguage.storageKey)
        if let lastLiveUsage {
            snapshot = UsageSnapshot(live: lastLiveUsage, language: newLanguage)
        } else {
            snapshot = previewOnly ? .preview(language: newLanguage) : .empty(language: newLanguage)
        }
        if !previewOnly { snapshot.apiCostEstimate = preservedCost }
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
            let now = Date()
            for source in [UsageSource.limits, .account, .threads] {
                let incoming = liveUsage.sourceHealth[source] ?? .success(at: now)
                if incoming.state == .live {
                    sourceHealth[source] = incoming
                } else {
                    sourceHealth[source] = (sourceHealth[source] ?? .loading)
                        .failing(incoming.message ?? "No data returned", at: now)
                }
            }
            let previous = lastLiveUsage
            let hasLimits = sourceHealth[.limits]?.state == .live
            let hasAccount = sourceHealth[.account]?.state == .live
            let hasThreads = sourceHealth[.threads]?.state == .live
            let mergedUsage = CodexLiveUsage(
                rateLimits: hasLimits ? liveUsage.rateLimits : (previous?.rateLimits ?? liveUsage.rateLimits),
                availableResetCount: hasLimits ? liveUsage.availableResetCount : previous?.availableResetCount,
                lifetimeTokens: hasAccount ? liveUsage.lifetimeTokens : previous?.lifetimeTokens,
                dailyUsage: hasAccount ? liveUsage.dailyUsage : (previous?.dailyUsage ?? []),
                recentThreads: hasThreads ? liveUsage.recentThreads : (previous?.recentThreads ?? []),
                apiCostEstimate: lastAPICostEstimate,
                dailyUsageAvailable: hasAccount ? liveUsage.dailyUsageAvailable : (previous?.dailyUsageAvailable ?? false),
                rateLimitBuckets: hasLimits ? liveUsage.rateLimitBuckets : (previous?.rateLimitBuckets ?? []),
                sourceHealth: sourceHealth
            )
            lastLiveUsage = mergedUsage
            snapshot = UsageSnapshot(live: mergedUsage, language: language)
            lastRefreshError = nil
            lastError = [UsageSource.limits, .account, .threads]
                .compactMap { sourceHealth[$0]?.message }.first
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            lastRefreshError = error
            lastError = Self.errorDescription(error, language: language)
            for source in [UsageSource.limits, .account, .threads] {
                sourceHealth[source] = (sourceHealth[source] ?? .loading)
                    .failing(lastError ?? "Refresh failed", at: Date())
            }
        }
    }

    public func refreshAPICost() async {
        guard !previewOnly, !isShuttingDown, !Task.isCancelled else { return }
        guard !isCostRefreshing else { return }
        isCostRefreshing = true
        defer { isCostRefreshing = false }

        let started = ProcessInfo.processInfo.systemUptime
        let result = await cancellableAPICostEstimate()
        guard !isShuttingDown, !Task.isCancelled else { return }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        UsageTelemetry.scans.info("Scan finished: duration_ms=\(milliseconds, privacy: .public) files=\(result?.health.discoveredFiles ?? 0, privacy: .public) unchanged=\(result?.health.unchangedFiles ?? 0, privacy: .public) issues=\(result?.health.issues.count ?? 0, privacy: .public) available=\(result?.estimate != nil, privacy: .public)")
        if let result { costHealth = result.health }
        guard let estimate = result?.estimate else {
            sourceHealth[.cost] = (sourceHealth[.cost] ?? .loading).failing(
                result?.failure ?? (language == .english ? "No estimate available; inspect local data health" : "暂无估算；请查看本机数据状态"),
                at: Date()
            )
            return
        }

        lastAPICostEstimate = estimate
        sourceHealth[.cost] = .success(at: Date())
        if var liveUsage = lastLiveUsage?.replacingAPICostEstimate(estimate) {
            liveUsage.sourceHealth = sourceHealth
            lastLiveUsage = liveUsage
            snapshot = UsageSnapshot(live: liveUsage, language: language)
        } else {
            snapshot.apiCostEstimate = APICostEstimateSnapshot(
                currentWeekUSD: estimate.currentWeekUSD,
                lifetimeUSD: estimate.lifetimeUSD,
                coveragePercent: estimate.observedTokens > 0
                    ? Int((Double(estimate.pricedTokens)
                        / Double(estimate.observedTokens) * 100).rounded())
                    : 0,
                modelNames: estimate.modelNames,
                hasPricedUsage: estimate.pricedTokens > 0,
                currentWeekHasPricedUsage: estimate.currentWeekPricedTokens.map { $0 > 0 } ?? (estimate.currentWeekUSD > 0)
            )
        }
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        await client.shutdown()
    }

    private func cancellableAPICostEstimate() async -> CostScanResult? {
        let bridge = APICostEstimateCancellationBridge()
        let estimator = apiCostEstimator
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard bridge.install(continuation) else { return }
                let worker = Task.detached(priority: .utility) {
                    bridge.finish(estimator())
                }
                bridge.attach(worker)
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
    private var continuation: CheckedContinuation<CostScanResult?, Never>?
    private var worker: Task<Void, Never>?
    private var isCancelled = false

    func install(
        _ continuation: CheckedContinuation<CostScanResult?, Never>
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

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled { lock.unlock(); task.cancel(); return }
        worker = task
        lock.unlock()
    }

    func finish(_ result: CostScanResult) {
        lock.lock()
        guard !isCancelled, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        let worker = worker
        self.worker = nil
        lock.unlock()
        worker?.cancel()
        continuation?.resume(returning: nil)
    }
}
