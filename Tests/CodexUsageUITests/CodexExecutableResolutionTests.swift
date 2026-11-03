import Foundation
import Testing
@testable import CodexUsageUI

struct CodexExecutableResolutionTests {
    @Test
    func defaultCandidatesCoverBothAppLayoutsAndFallbacksInOrder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(CodexAppServerClient.defaultCodexExecutableCandidates.map(\.path) == [
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
    }

    @Test
    func newAppLayoutTakesPriorityAndLegacyLayoutStillWorks() throws {
        let fixture = try ExecutableResolutionFixture()
        defer { fixture.remove() }
        let newLayout = fixture.url("Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let legacyLayout = fixture.url("Codex.app/Contents/Resources/codex")
        let homebrewFallback = fixture.url("homebrew/bin/codex")
        let candidates = [newLayout, legacyLayout, homebrewFallback]

        try fixture.makeFile(legacyLayout, executable: true)
        try fixture.makeFile(homebrewFallback, executable: true)
        #expect(try CodexAppServerClient.resolveCodexExecutable(candidates: candidates) == legacyLayout)

        try fixture.makeFile(newLayout, executable: true)
        #expect(try CodexAppServerClient.resolveCodexExecutable(candidates: candidates) == newLayout)
    }

    @Test
    func skipsDirectoriesAndNonExecutableFiles() throws {
        let fixture = try ExecutableResolutionFixture()
        defer { fixture.remove() }
        let directory = fixture.url("directory-candidate")
        let nonExecutable = fixture.url("non-executable")
        let fallback = fixture.url("fallback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.makeFile(nonExecutable, executable: false)
        try fixture.makeFile(fallback, executable: true)

        #expect(try CodexAppServerClient.resolveCodexExecutable(
            candidates: [directory, nonExecutable, fallback]
        ) == fallback)
    }

    @Test
    func reportsExecutableNotFoundWhenAllCandidatesAreUnusable() throws {
        let fixture = try ExecutableResolutionFixture()
        defer { fixture.remove() }
        let missing = fixture.url("missing")
        let directory = fixture.url("directory-candidate")
        let nonExecutable = fixture.url("non-executable")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.makeFile(nonExecutable, executable: false)

        do {
            _ = try CodexAppServerClient.resolveCodexExecutable(
                candidates: [missing, directory, nonExecutable]
            )
            Issue.record("Expected executableNotFound")
        } catch let error as CodexUsageClientError {
            guard case .executableNotFound = error else {
                Issue.record("Expected executableNotFound, got \(error)")
                return
            }
        }
    }

    @Test
    func liveSwiftClientReadsUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_LIVE_USAGE_DIAGNOSTIC"] == "1" else {
            return
        }
        let client = CodexAppServerClient(responseTimeout: 20)
        let usage: CodexLiveUsage
        do {
            usage = try await client.fetchUsage(apiCostEstimate: nil)
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()

        guard let primary = usage.rateLimits.primary else {
            Issue.record("Live Swift decode returned no primary rate-limit window")
            return
        }
        #expect(primary.usedPercent.isFinite)
        #expect(primary.windowDurationMinutes != nil)
        print("LIVE_SWIFT_RATE_LIMITS_OK; client child process shut down")
    }
}

private struct ExecutableResolutionFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexExecutableResolutionTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func makeFile(_ url: URL, executable: Bool) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
