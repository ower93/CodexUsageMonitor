import Foundation
import Testing
@testable import CodexUsageUI

struct UsageRefreshCoordinatorTests {
    @Test @MainActor
    func startIsIdempotentAndStopDoesNotTriggerTailRefresh() async throws {
        let target = RefreshTargetSpy()
        let coordinator = UsageRefreshCoordinator(
            target: target,
            liveRefreshInterval: .seconds(60),
            costRefreshInterval: .seconds(900)
        )

        coordinator.start()
        coordinator.start()
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.liveRefreshCount == 1)
        #expect(target.costRefreshCount == 1)

        await coordinator.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.liveRefreshCount == 1)
        #expect(target.costRefreshCount == 1)
        #expect(target.shutdownCount == 1)
    }

    @Test @MainActor
    func manualRefreshCanSkipOrIncludeCost() async {
        let target = RefreshTargetSpy()
        let coordinator = UsageRefreshCoordinator(
            target: target,
            liveRefreshInterval: .seconds(60),
            costRefreshInterval: .seconds(900)
        )

        await coordinator.refreshNow(includeCost: false)
        await coordinator.refreshNow(includeCost: true)

        #expect(target.liveRefreshCount == 2)
        #expect(target.costRefreshCount == 1)
        await coordinator.stop()
    }

    @Test @MainActor
    func stopCancelsAndWaitsForActiveLoops() async {
        let target = BlockingRefreshTarget()
        let coordinator = UsageRefreshCoordinator(
            target: target,
            liveRefreshInterval: .seconds(60),
            costRefreshInterval: .seconds(900)
        )

        coordinator.start()
        await target.waitUntilBothRefreshesStart()
        await coordinator.stop()

        #expect(target.liveRefreshFinished)
        #expect(target.costRefreshFinished)
        #expect(target.shutdownCount == 1)

        try? await Task.sleep(for: .milliseconds(20))
        #expect(target.liveRefreshCount == 1)
        #expect(target.costRefreshCount == 1)
    }
}

@MainActor
private final class RefreshTargetSpy: UsageRefreshTarget {
    private(set) var liveRefreshCount = 0
    private(set) var costRefreshCount = 0
    private(set) var shutdownCount = 0

    func refreshLive() async {
        liveRefreshCount += 1
    }

    func refreshAPICost() async {
        costRefreshCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

@MainActor
private final class BlockingRefreshTarget: UsageRefreshTarget {
    private(set) var liveRefreshCount = 0
    private(set) var costRefreshCount = 0
    private(set) var shutdownCount = 0
    private(set) var liveRefreshFinished = false
    private(set) var costRefreshFinished = false

    func refreshLive() async {
        liveRefreshCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {}
        liveRefreshFinished = true
    }

    func refreshAPICost() async {
        costRefreshCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {}
        costRefreshFinished = true
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func waitUntilBothRefreshesStart() async {
        while liveRefreshCount == 0 || costRefreshCount == 0 {
            await Task.yield()
        }
    }
}
