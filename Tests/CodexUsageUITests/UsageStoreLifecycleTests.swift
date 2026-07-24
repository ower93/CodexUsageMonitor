import Foundation
import Testing
@testable import CodexUsageUI

struct UsageStoreLifecycleTests {
    @Test @MainActor
    func liveRefreshMergesTheNewestCostEstimateWhenItReturns() async throws {
        let client = SuspendedUsageClient()
        let estimate = CodexAPICostEstimate(
            sevenDayUSD: 12,
            lifetimeUSD: 34,
            pricedTokens: 100,
            observedTokens: 100,
            modelNames: ["test-model"]
        )
        let store = UsageStore(
            language: .english,
            client: client,
            apiCostEstimator: { estimate }
        )

        let liveTask = Task { @MainActor in
            await store.refreshLive()
        }
        await client.waitUntilFetchStarts()
        await store.refreshAPICost()
        await client.complete(with: Self.liveUsage)
        await liveTask.value

        #expect(store.snapshot.apiCostEstimate?.sevenDayUSD == 12)
        #expect(store.snapshot.apiCostEstimate?.lifetimeUSD == 34)
        await store.shutdown()
    }

    @Test @MainActor
    func cancelledCostRefreshReturnsPromptlyAndDoesNotUpdateTheSnapshot() async throws {
        let estimator = BlockingCostEstimator()
        let client = ImmediateUsageClient()
        let store = UsageStore(
            language: .english,
            client: client,
            apiCostEstimator: {
                estimator.estimate()
            }
        )
        let originalCost = store.snapshot.apiCostEstimate?.lifetimeUSD

        let refreshTask = Task { @MainActor in
            await store.refreshAPICost()
        }
        try await estimator.waitUntilStarted(timeout: 1)

        let startedAt = Date()
        refreshTask.cancel()
        await refreshTask.value
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 0.5)
        #expect(store.snapshot.apiCostEstimate?.lifetimeUSD == originalCost)

        estimator.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.snapshot.apiCostEstimate?.lifetimeUSD == originalCost)
        await store.shutdown()
    }

    private static let liveUsage = CodexLiveUsage(
        rateLimits: CodexRateLimitSnapshot(
            planType: "pro",
            primary: CodexRateLimitWindow(
                usedPercent: 25,
                windowDurationMinutes: 300,
                resetsAt: nil
            ),
            secondary: nil
        ),
        availableResetCount: 1,
        lifetimeTokens: 123,
        dailyUsage: [],
        recentThreads: [],
        apiCostEstimate: nil
    )
}

private actor SuspendedUsageClient: CodexUsageFetching {
    private var didStart = false
    private var continuation: CheckedContinuation<CodexLiveUsage, Error>?

    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func shutdown() async {
        continuation?.resume(throwing: CodexUsageClientError.shuttingDown)
        continuation = nil
    }

    func waitUntilFetchStarts() async {
        while !didStart {
            await Task.yield()
        }
    }

    func complete(with usage: CodexLiveUsage) {
        continuation?.resume(returning: usage)
        continuation = nil
    }
}

private struct ImmediateUsageClient: CodexUsageFetching {
    func fetchUsage(apiCostEstimate: CodexAPICostEstimate?) async throws -> CodexLiveUsage {
        CodexLiveUsage(
            rateLimits: CodexRateLimitSnapshot(
                planType: "pro",
                primary: nil,
                secondary: nil
            ),
            availableResetCount: 0,
            lifetimeTokens: 0,
            dailyUsage: [],
            recentThreads: [],
            apiCostEstimate: apiCostEstimate
        )
    }

    func shutdown() async {}
}

private final class BlockingCostEstimator: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var didStart = false

    func estimate() -> CodexAPICostEstimate? {
        lock.lock()
        didStart = true
        lock.unlock()
        releaseSemaphore.wait()
        return CodexAPICostEstimate(
            sevenDayUSD: 99,
            lifetimeUSD: 999,
            pricedTokens: 100,
            observedTokens: 100,
            modelNames: ["blocked-model"]
        )
    }

    func waitUntilStarted(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if startedSnapshot() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BlockingCostEstimatorError.startTimedOut
    }

    func release() {
        releaseSemaphore.signal()
    }

    private func startedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }
}

private enum BlockingCostEstimatorError: Error {
    case startTimedOut
}
