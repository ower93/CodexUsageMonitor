import Darwin
import Foundation
import Testing
@testable import CodexUsageUI

@Suite(.serialized)
struct CodexAppServerClientLifecycleTests {
    @Test
    func reusesOneProcessAcrossRepeatedRefreshesAndClosesIt() async throws {
        let fixture = try FakeAppServerFixture(mode: .respond)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL,
            responseTimeout: 2,
            shutdownTimeout: 0.5
        )

        for _ in 0..<500 {
            let usage = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(usage.rateLimits.planType == "pro")
            #expect(usage.lifetimeTokens == 123)
        }
        await client.shutdown()
        await client.shutdown()

        let events = try fixture.events()
        #expect(events.filter { $0 == "start" }.count == 1)
        #expect(events.filter { $0 == "stop" }.count == 1)
    }

    @Test
    func timeoutTearsDownEachFailedProcess() async throws {
        let fixture = try FakeAppServerFixture(mode: .hangAfterInitialize)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL,
            responseTimeout: 2,
            shutdownTimeout: 0.2
        )

        do {
            _ = try await client.fetchUsage(apiCostEstimate: nil)
            Issue.record("Expected the fake app-server request to time out")
        } catch {
            #expect(error is CodexUsageClientError)
        }
        await client.shutdown()

        let events = try fixture.events()
        let starts = events.filter { $0 == "start" }.count
        let stops = events.filter { $0 == "stop" }.count
        // The client makes at most two attempts. Under heavy scheduler load,
        // the retry can be terminated before the shell executes its first
        // instruction, so only processes that actually started can emit events.
        #expect((1...2).contains(starts))
        #expect(stops == starts)
    }

    @Test
    func shutdownInterruptsAnActiveRequestWithoutRetrying() async throws {
        let fixture = try FakeAppServerFixture(mode: .ignoreTermination)
        defer { fixture.remove() }
        let client = CodexAppServerClient(
            executableURL: fixture.executableURL,
            responseTimeout: 30,
            shutdownTimeout: 0.4
        )

        let fetchTask = Task {
            try await client.fetchUsage(apiCostEstimate: nil)
        }
        try await fixture.waitForEvent("hang", timeout: 5)

        let startedAt = Date()
        await client.shutdown()
        let elapsed = Date().timeIntervalSince(startedAt)

        do {
            _ = try await fetchTask.value
            Issue.record("Expected shutdown to interrupt the active request")
        } catch let error as CodexUsageClientError {
            guard case .shuttingDown = error else {
                Issue.record("Expected shuttingDown, got \(error)")
                return
            }
        }

        let events = try fixture.events()
        #expect(events.filter { $0 == "start" }.count == 1)
        #expect(elapsed < 1)
        if let processID = try fixture.processID() {
            #expect(Darwin.kill(processID, 0) != 0)
        } else {
            Issue.record("The fake app-server did not record its process ID")
        }
    }
}

private struct FakeAppServerFixture {
    enum Mode {
        case respond
        case hangAfterInitialize
        case ignoreTermination
    }

    let directoryURL: URL
    let executableURL: URL
    private let eventURL: URL
    private let processIDURL: URL

    init(mode: Mode) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageMonitorTests-\(UUID().uuidString)", isDirectory: true)
        executableURL = directoryURL.appendingPathComponent("fake-app-server")
        eventURL = directoryURL.appendingPathComponent("events.txt")
        processIDURL = directoryURL.appendingPathComponent("pid.txt")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let respondToRequests: String
        switch mode {
        case .respond:
            respondToRequests = """
              *account*rateLimits*read*)
                echo "{\\"id\\":$id,\\"result\\":{\\"rateLimits\\":{\\"primary\\":{\\"usedPercent\\":40,\\"windowDurationMins\\":300,\\"resetsAt\\":null},\\"secondary\\":{\\"usedPercent\\":25,\\"windowDurationMins\\":10080,\\"resetsAt\\":null},\\"planType\\":\\"pro\\"},\\"rateLimitResetCredits\\":{\\"availableCount\\":1}}}"
                ;;
              *account*usage*read*)
                echo "{\\"id\\":$id,\\"result\\":{\\"summary\\":{\\"lifetimeTokens\\":123},\\"dailyUsageBuckets\\":[]}}"
                ;;
              *thread*list*)
                echo "{\\"id\\":$id,\\"result\\":{\\"data\\":[]}}"
                ;;
            """
        case .hangAfterInitialize:
            respondToRequests = """
              *)
                :
                ;;
            """
        case .ignoreTermination:
            respondToRequests = """
              *)
                echo hang >> "\(eventURL.path)"
                trap '' TERM
                while :; do :; done
                ;;
            """
        }

        let script = """
        #!/bin/sh
        echo $$ > "\(processIDURL.path)"
        echo start >> "\(eventURL.path)"
        trap 'echo stop >> "\(eventURL.path)"' EXIT
        while IFS= read -r line; do
          id=${line#*'"id":'}
          id=${id%%,*}
          id=${id%%\\}*}
          case "$line" in
            *initialized*)
              :
              ;;
            *initialize*)
              echo "{\\"id\\":$id,\\"result\\":{}}"
              ;;
        \(respondToRequests)
          esac
        done
        """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func events() throws -> [String] {
        guard FileManager.default.fileExists(atPath: eventURL.path) else { return [] }
        return try String(contentsOf: eventURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func processID() throws -> pid_t? {
        guard FileManager.default.fileExists(atPath: processIDURL.path) else { return nil }
        let value = try String(contentsOf: processIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(value)
    }

    func waitForEvent(_ event: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try events().contains(event) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FakeAppServerError.eventTimedOut(event)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum FakeAppServerError: Error {
    case eventTimedOut(String)
}
