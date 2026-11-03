import Foundation
import Testing
@testable import CodexUsageUI

struct RefreshEventsTests {
    @Test @MainActor
    func nativeFileEventsObserveNewSessionData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = EventCounter()
        // /var and /private/var may resolve to the same folder on macOS.
        let watcher = SessionChangeWatcher(home: directory) { counter.increment() }
        defer { watcher.stop() }
        #expect(watcher.isActive)
        try await Task.sleep(for: .milliseconds(250))
        try Data("{}\n".utf8).write(to: sessions.appendingPathComponent("test.jsonl"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while counter.value == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value > 0)
    }

    @Test
    func backoffIsBoundedAndLowPowerReducesFrequency() {
        #expect(RefreshPolicy.interval(base: .seconds(60), failures: 0, lowPower: false) == .seconds(60))
        #expect(RefreshPolicy.interval(base: .seconds(60), failures: 2, lowPower: false) == .seconds(240))
        #expect(RefreshPolicy.interval(base: .seconds(60), failures: 99, lowPower: true) == .seconds(1800))
    }

    @Test @MainActor
    func coalescesEventsAndPausesDuringSleep() async throws {
        let target = EventTarget()
        let coordinator = UsageRefreshCoordinator(target: target, liveRefreshInterval: .seconds(60), costRefreshInterval: .seconds(900),
            eventDelay: .milliseconds(10), costEventDelay: .milliseconds(10))
        coordinator.start()
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<100 { coordinator.quotaChanged(); coordinator.sessionFilesChanged() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(target.liveCount == 2)
        #expect(target.costCount == 2)
        await coordinator.setSleeping(true)
        for _ in 0..<20 { coordinator.quotaChanged(); coordinator.sessionFilesChanged() }
        await coordinator.refreshNow()
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 2)
        #expect(target.costCount == 2)
        await coordinator.setSleeping(false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 3)
        #expect(target.costCount == 3)
        coordinator.quotaChanged(); coordinator.sessionFilesChanged()
        await coordinator.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 3)
        #expect(target.costCount == 3)
    }

    @Test
    func stdoutDrainsIdleNotificationsAndDeduplicatesPayloads() async throws {
        let pipe = Pipe()
        let counter = EventCounter()
        let reader = SessionOutputReader(handle: pipe.fileHandleForReading) { counter.increment() }
        defer { reader.stop(); try? pipe.fileHandleForWriting.close() }
        let event = #"{"method":"account/rateLimits/updated","params":{"usedPercent":12}}"# + "\n"
        try pipe.fileHandleForWriting.write(contentsOf: Data((event + event).utf8))
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.value == 1) // No RPC consumer was waiting.
        let response = #"{"id":1,"result":{}}"#
        try pipe.fileHandleForWriting.write(contentsOf: Data((response + "\n").utf8))
        #expect(String(data: try reader.next(timeout: 1), encoding: .utf8) == response)
        reader.stop()
        #expect(throws: CodexUsageClientError.self) { try reader.next(timeout: 1) }
    }

    @Test @MainActor
    func wakeWaitsForCancelledWorkBeforeStartingNewLoops() async throws {
        let target = SuspendedEventTarget()
        let coordinator = UsageRefreshCoordinator(target: target, liveRefreshInterval: .seconds(60),
            costRefreshInterval: .seconds(900), eventDelay: .milliseconds(10))
        coordinator.start()
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 1)
        let sleeping = Task { await coordinator.setSleeping(true) }
        try await Task.sleep(for: .milliseconds(20))
        let waking = Task { await coordinator.setSleeping(false) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(target.liveCount == 1)
        target.releaseFirstRefresh()
        await sleeping.value
        await waking.value
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 2)
        for _ in 0..<10 { coordinator.quotaChanged() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(target.liveCount == 3)
        await coordinator.stop()
    }
}

@MainActor
private final class SuspendedEventTarget: UsageRefreshTarget {
    var liveCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func refreshLive() async {
        liveCount += 1
        if liveCount == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func releaseFirstRefresh() { continuation?.resume(); continuation = nil }
    func refreshAPICost() async {}
    func shutdown() async { releaseFirstRefresh() }
}

@MainActor
private final class EventTarget: UsageRefreshTarget {
    var liveCount = 0
    var costCount = 0
    func refreshLive() async { liveCount += 1 }
    func refreshAPICost() async { costCount += 1 }
    func shutdown() async {}
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
