import Foundation
import Testing
@testable import CodexUsageUI

/// Opt-in, local-only benchmark. The caller supplies an isolated ledger copy
/// and frozen log snapshot; normal test runs never read the user's logs.
struct IndexPerformanceTests {
    @Test
    func isolatedColdAndWarmScan() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEX_USAGE_BENCHMARK_DIR"],
              let source = ProcessInfo.processInfo.environment["CODEX_USAGE_BENCHMARK_SOURCE"]
        else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsageMonitor")
            .standardizedFileURL.resolvingSymlinksInPath()
        #expect(directory != production)
        guard directory != production else { return }
        let ledgerURL = directory.appendingPathComponent("token-cost-ledger.json")
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))
        let sourceURL = URL(fileURLWithPath: source)
        let roots = [sourceURL.appendingPathComponent("sessions"), sourceURL.appendingPathComponent("archived_sessions")]
        for root in roots { try #require(FileManager.default.isReadableFile(atPath: root.path)) }
        let now = Date(timeIntervalSince1970: 1_791_216_000)
        let before = try APICostLedgerStore(url: ledgerURL).load()
        for phase in ["cold", "warm"] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = SessionAPICostEstimator.scan(now: now, ledgerURL: ledgerURL, sessionRoots: roots)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try #require(result.failure == nil)
            try #require(result.estimate != nil)
            print("INDEX_BENCHMARK phase=\(phase) seconds=\(String(format: "%.3f", elapsed)) files=\(result.health.discoveredFiles) unchanged=\(result.health.unchangedFiles) issues=\(result.health.issues.count)")
        }
        let after = try APICostLedgerStore(url: ledgerURL).load()
        for frozen in before.records {
            let extended = try #require(after.records.first {
                $0.sessionID == frozen.sessionID && $0.usageDay == frozen.usageDay && $0.model == frozen.model
                    && $0.price == frozen.price && $0.pricingBackfill == frozen.pricingBackfill
                    && $0.accountingNote == frozen.accountingNote
            }, "Frozen price/category group must survive the rebuild")
            let added = try #require(extended.counts.delta(since: frozen.counts))
            let addedUSD = frozen.price.map { SessionAPICostEstimator.estimatedUSD(price: $0, counts: added) } ?? 0
            #expect(abs(extended.usd - frozen.usd - addedUSD) < 0.000_001)
        }
        print("INDEX_FROZEN_HISTORY verifiedGroups=\(before.records.count) silentlyRepriced=false")
    }
}
