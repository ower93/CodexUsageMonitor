import Darwin
import Foundation
import Testing
@testable import CodexUsageUI

@Suite(.serialized)
struct CodexAppServerClientLifecycleTests {
    @Test
    func revokedSessionReconnectsOnceAndReusesTheFreshProcess() async throws {
        try await withFakeClient(mode: .respond, expectedStarts: 2) { client, fixture in
            let initial = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(initial.sourceHealth[.limits]?.state == .live)
            let processID = try fixture.processID()
            let oldPID = try #require(processID)
            try Data().write(to: fixture.directoryURL.appendingPathComponent("expire-session"))

            let recovered = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(recovered.sourceHealth[.limits]?.state == .live)
            #expect(recovered.rateLimits.primary?.usedPercent == 40)
            #expect(recovered.lifetimeTokens == 123)
            #expect(Darwin.kill(oldPID, 0) != 0)
            for _ in 0..<10 {
                let usage = try await client.fetchUsage(apiCostEstimate: nil)
                #expect(usage.sourceHealth[.limits]?.state == .live)
            }
        }
    }

    @Test
    func accountOnlyAuthenticationFailureAlsoReconnects() async throws {
        try await withFakeClient(mode: .accountAuthFailureUntilRestart, expectedStarts: 2) { client, _ in
            let usage = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(usage.sourceHealth[.limits]?.state == .live)
            #expect(usage.sourceHealth[.account]?.state == .live)
            #expect(usage.sourceHealth[.threads]?.state == .live)
            #expect(usage.lifetimeTokens == 123)
        }
    }

    @Test
    func persistentAuthenticationFailureStopsAfterOneRetryAndKeepsOtherSources() async throws {
        try await withFakeClient(mode: .persistentAuthFailure, expectedStarts: 2) { client, fixture in
            let usage = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(usage.sourceHealth[.limits]?.state == .unavailable)
            #expect(usage.sourceHealth[.limits]?.message?.contains("token_revoked") == true)
            #expect(usage.rateLimits.primary == nil)
            #expect(usage.sourceHealth[.account]?.state == .live)
            #expect(usage.sourceHealth[.threads]?.state == .live)
            #expect(usage.lifetimeTokens == 123)
            #expect(try fixture.events().filter { $0 == "stop" }.count == 2)
        }
    }

    @Test
    func unsupportedQuotaEndpointDoesNotRestartAHealthyConnection() async throws {
        try await withFakeClient(mode: .quotaUnavailable, expectedStarts: 1) { client, _ in
            for _ in 0..<10 {
                let usage = try await client.fetchUsage(apiCostEstimate: nil)
                #expect(usage.sourceHealth[.limits]?.state == .unavailable)
                #expect(usage.sourceHealth[.account]?.state == .live)
                #expect(usage.lifetimeTokens == 123)
            }
        }
    }

    @Test
    func failedAuthenticationReconnectRetainsAlreadySuccessfulSources() async throws {
        try await withFakeClient(mode: .authFailureThenConnectionCloses, expectedStarts: 2) { client, _ in
            let usage = try await client.fetchUsage(apiCostEstimate: nil)
            #expect(usage.sourceHealth[.limits]?.state == .unavailable)
            #expect(usage.sourceHealth[.account]?.state == .live)
            #expect(usage.sourceHealth[.threads]?.state == .live)
            #expect(usage.lifetimeTokens == 123)
        }
    }

    @Test
    func repeatedOfflineTransportFailuresRecoverWithoutRestartingTheClient() async throws {
        let fixture = try FakeAppServerFixture(mode: .respond)
        defer { fixture.remove() }
        // This verifies recovery, not sub-second process launch performance.
        // Concurrent native AX/audit work can delay a newly spawned shell on
        // this Mac. Keep the same response budget as the other lifecycle tests;
        // timeout/teardown behavior has its own dedicated test below.
        let client = CodexAppServerClient(executableURL: fixture.executableURL, responseTimeout: 2, shutdownTimeout: 0.2)
        let offline = fixture.directoryURL.appendingPathComponent("offline")
        do {
            for _ in 0..<10 {
                let usage = try await client.fetchUsage(apiCostEstimate: nil)
                #expect(usage.rateLimits.primary?.usedPercent == 40)
                try Data().write(to: offline)
                do {
                    _ = try await client.fetchUsage(apiCostEstimate: nil)
                    Issue.record("Expected offline transport failure")
                } catch { #expect(error is CodexUsageClientError) }
                try FileManager.default.removeItem(at: offline)
            }
            _ = try await client.fetchUsage(apiCostEstimate: nil)
        } catch {
            // Do not leave a helper behind when the assertion path throws.
            await client.shutdown()
            throw error
        }
        await client.shutdown()
        let events = try fixture.events()
        #expect(events.filter { $0 == "start" }.count == events.filter { $0 == "stop" }.count)
        if let pid = try fixture.processID() { #expect(Darwin.kill(pid, 0) != 0) }
    }

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

private func withFakeClient(
    mode: FakeAppServerFixture.Mode,
    expectedStarts: Int,
    operation: (CodexAppServerClient, FakeAppServerFixture) async throws -> Void
) async throws {
    let fixture = try FakeAppServerFixture(mode: mode)
    defer { fixture.remove() }
    let client = CodexAppServerClient(executableURL: fixture.executableURL,
                                      responseTimeout: 2, shutdownTimeout: 0.5)
    do {
        try await operation(client, fixture)
    } catch {
        await client.shutdown()
        throw error
    }
    await client.shutdown()
    let events = try fixture.events()
    #expect(events.filter { $0 == "start" }.count == expectedStarts)
    #expect(events.filter { $0 == "stop" }.count == expectedStarts)
    if let pid = try fixture.processID() { #expect(Darwin.kill(pid, 0) != 0) }
}

private struct FakeAppServerFixture {
    enum Mode: Equatable {
        case respond
        case accountAuthFailureUntilRestart
        case persistentAuthFailure
        case authFailureThenConnectionCloses
        case quotaUnavailable
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

        let authSetup: String
        switch mode {
        case .accountAuthFailureUntilRestart:
            authSetup = """
            auth_failure_scope=account
            if [ ! -f "\(directoryURL.path)/restarted" ]; then
              : > "\(directoryURL.path)/restarted"
              reject_auth=yes
            fi
            """
        case .persistentAuthFailure:
            authSetup = "reject_auth=yes"
        case .authFailureThenConnectionCloses:
            authSetup = """
            if [ -f "\(directoryURL.path)/restarted" ]; then exit 1; fi
            : > "\(directoryURL.path)/restarted"
            reject_auth=yes
            """
        default:
            authSetup = ""
        }
        let authError = #"echo "{\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"401 Unauthorized: Encountered invalidated oauth token; token_revoked\"}}""#
        let quotaResponse = mode == .quotaUnavailable
            ? #"echo "{\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"Endpoint unavailable\"}}""#
            : #"echo "{\"id\":$id,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":40,\"windowDurationMins\":300,\"resetsAt\":null},\"secondary\":{\"usedPercent\":25,\"windowDurationMins\":10080,\"resetsAt\":null},\"planType\":\"pro\"},\"rateLimitResetCredits\":{\"availableCount\":1}}}""#
        let respondToRequests: String
        switch mode {
        case .respond, .accountAuthFailureUntilRestart, .persistentAuthFailure, .authFailureThenConnectionCloses, .quotaUnavailable:
            respondToRequests = """
              *account*rateLimits*read*)
                if [ "$reject_auth" = yes ] && [ "$auth_failure_scope" = limits ]; then
                  \(authError)
                else
                  \(quotaResponse)
                fi
                ;;
              *account*usage*read*)
                if [ "$reject_auth" = yes ] && [ "$auth_failure_scope" = account ]; then
                  \(authError)
                else
                  echo "{\\"id\\":$id,\\"result\\":{\\"summary\\":{\\"lifetimeTokens\\":123},\\"dailyUsageBuckets\\":[]}}"
                fi
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
        reject_auth=no
        auth_failure_scope=limits
        fresh_at_launch=no
        if [ -f "\(directoryURL.path)/expire-session" ]; then fresh_at_launch=yes; fi
        \(authSetup)
        while IFS= read -r line; do
          if [ -f "\(directoryURL.path)/offline" ]; then exit 1; fi
          if [ "$fresh_at_launch" = no ] && [ -f "\(directoryURL.path)/expire-session" ]; then reject_auth=yes; fi
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
