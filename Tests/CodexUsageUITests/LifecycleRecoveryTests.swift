import AppKit
import Foundation
import Testing
@testable import CodexUsageUI

struct LifecycleRecoveryTests {
    @Test func networkRecoveryOnlySignalsAnActualTransition() {
        var state = NetworkRecoveryState()
        let results = [state.update(reachable: true), state.update(reachable: true),
                       state.update(reachable: false), state.update(reachable: true), state.update(reachable: true)]
        #expect(results == [false, false, false, true, false])
    }

    @Test @MainActor func restoredConnectionRetriesWithoutWaitingForBackoff() async throws {
        let target = RecoveryTarget()
        target.liveRefreshSucceeded = false
        let coordinator = UsageRefreshCoordinator(target: target, liveRefreshInterval: .seconds(60), costRefreshInterval: .seconds(900))
        coordinator.start()
        try await waitFor { target.liveCount == 1 }
        target.liveRefreshSucceeded = true
        coordinator.connectionRestored()
        try await waitFor { target.liveCount == 2 }
        #expect(target.costCount == 1)
        await coordinator.stop()
        coordinator.connectionRestored()
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.liveCount == 2)
    }

    @Test @MainActor func repeatedRestorationDrainsInflightWorkBeforeRestarting() async throws {
        let target = RecoveryTarget()
        target.holdFirst = true
        let coordinator = UsageRefreshCoordinator(target: target, liveRefreshInterval: .seconds(60), costRefreshInterval: .seconds(900))
        coordinator.start()
        try await waitFor { target.liveCount == 1 }
        for _ in 0..<20 { coordinator.connectionRestored() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.liveCount == 1)
        target.release()
        try await waitFor { target.liveCount == 2 }
        #expect(target.maximumConcurrent == 1)
        await coordinator.stop()
    }

    @Test @MainActor func systemNotificationRoutingSurvivesRepeatedSleepWakeAndObserverCleanup() async throws {
        let target = RecoveryTarget()
        let coordinator = UsageRefreshCoordinator(target: target, liveRefreshInterval: .seconds(60), costRefreshInterval: .seconds(900),
                                                  eventDelay: .milliseconds(2), costEventDelay: .milliseconds(2))
        let workspace = NotificationCenter()
        let power = NotificationCenter()
        let observer = UsageLifecycleObserver(coordinator: coordinator, workspaceCenter: workspace,
                                               powerCenter: power, lowPower: { true })
        coordinator.start()
        try await waitFor { target.liveCount == 1 && target.costCount == 1 }
        for cycle in 1...20 {
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await Task.sleep(for: .milliseconds(10))
            for _ in 0..<20 { coordinator.quotaChanged(); coordinator.sessionFilesChanged(); coordinator.connectionRestored() }
            power.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(10))
            #expect(target.liveCount == cycle)
            #expect(target.costCount == cycle)
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await waitFor { target.liveCount == cycle + 1 && target.costCount == cycle + 1 }
        }
        #expect(target.maximumConcurrent == 1)
        observer.stop()
        observer.stop()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.refreshNow()
        #expect(target.liveCount == 22)
        #expect(target.costCount == 22)
        await coordinator.stop()
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }
}

@MainActor private final class RecoveryTarget: UsageRefreshTarget {
    var liveCount = 0
    var costCount = 0
    var liveRefreshSucceeded = true
    var holdFirst = false
    var maximumConcurrent = 0
    private var active = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func refreshLive() async {
        liveCount += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        if holdFirst && liveCount == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
    func refreshAPICost() async { costCount += 1 }
    func shutdown() async { release() }
}
