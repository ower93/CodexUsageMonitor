import Foundation
import Testing
@testable import CodexUsageUI

struct AccountingV2Tests {
    @Test
    func parentContinuationBaselinesDoNotDependOnFileEnumerationOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("parent-original.jsonl")
        let continuation = dir.appendingPathComponent("parent-continuation.jsonl")
        let child = dir.appendingPathComponent("child.jsonl")
        func save(_ lines: [[String: Any]], _ url: URL) throws {
            try lines.reduce(into: Data()) { data, line in
                data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10)
            }.write(to: url)
        }
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": "parent"]]
        try save([header, event(counts(100, 50, 10), at: "2026-10-06T01:00:00Z")], original)
        try save([header, event(counts(100, 50, 10), at: "2026-10-06T01:00:00Z"),
                  event(counts(1000, 800, 100), at: "2026-10-06T02:00:00Z")], continuation)
        try save([["type": "session_meta", "payload": ["id": "child", "parent_thread_id": "parent", "timestamp": "2026-10-06T02:01:00Z"]],
                  event(counts(500, 300, 20), at: "2026-10-06T02:02:00Z")], child)
        let descriptors = [original, continuation, child].map(SessionUsageLogReader.descriptor(for:))
        let forward = SessionUsageLogReader.inheritedBaselines(for: descriptors)
        let reverse = SessionUsageLogReader.inheritedBaselines(for: descriptors.reversed())
        #expect(forward == reverse)
        #expect(forward["child"] == .zero)
        // Contradictory snapshots at one timestamp must remain unpriced.
        try save([header, event(counts(200, 100, 10), at: "2026-10-06T02:00:00Z")], original)
        #expect(SessionUsageLogReader.inheritedBaselines(for: descriptors)["child"] == nil)
    }

    @Test
    func unknownCurrentWeekPriceIsNotAConfirmedZeroCost() throws {
        var ledger = APICostLedger()
        ledger.observe(sessionID: "unpriced", summary: summary(counts(100, 50, 20)),
            initialUsageDay: "2026-10-06", incrementalUsageDay: "2026-10-06", price: nil)
        let result = try #require(ledger.estimate(currentWeekDayKeys: ["2026-10-06"]))
        #expect(result.observedTokens == 120)
        #expect(result.pricedTokens == 0)
        #expect(result.currentWeekPricedTokens == 0)
    }

    @Test
    func rawCategoryDeltasTelescopeWithoutClamping() throws {
        let prior = counts(1000, 800, 20)
        let intermediate = counts(1100, 1000, 30)
        let latest = counts(1400, 1100, 40)
        let first = try #require(intermediate.delta(since: prior))
        let second = try #require(latest.delta(since: intermediate))
        #expect(first.cachedInputTokens == 200)
        #expect(first.inputTokens == 100)
        #expect(first.accountingIssue == "inconsistent-cache-delta")
        var sum = first
        sum.add(second)
        #expect(sum == latest.delta(since: prior))
    }

    @Test
    func acceptsWholeIncrementButDoesNotGuessAmbiguousCategoryPrice() throws {
        var ledger = APICostLedger()
        let originalPrice = try #require(APIModelPrice.price(for: "gpt-6-astra"))
        ledger.observe(sessionID: "root", summary: summary(counts(1000, 800, 20)),
                       initialUsageDay: "2026-09-07", incrementalUsageDay: "2026-09-07", price: originalPrice)
        let frozen = ledger.records[0]
        let anomalous = try #require(counts(1100, 1000, 30).delta(since: counts(1000, 800, 20)))
        let normal = try #require(counts(1400, 1100, 40).delta(since: counts(1100, 1000, 30)))
        let slices = [
            SessionUsageSlice(usageDay: "2026-09-08", model: "gpt-6-astra", counts: anomalous,
                              accountingNote: anomalous.accountingIssue),
            SessionUsageSlice(usageDay: "2026-09-08", model: "gpt-6-astra", counts: normal)
        ]
        let accepted = ledger.observeIncrement(sessionID: "root", summary: summary(counts(1400, 1100, 40)), slices: slices)
        #expect(accepted)
        #expect(ledger.records.first == frozen)
        #expect(ledger.records.reduce(0) { $0 + $1.counts.totalTokens } == 1440)
        let excluded = try #require(ledger.records.first { $0.accountingNote != nil })
        #expect(excluded.price == nil)
        #expect(excluded.usd == 0)
        #expect(excluded.counts.totalTokens == 110)
        #expect(!ledger.hasUnpricedGPT6Usage)
        #expect(ledger.backfillUnpricedGPT6Usage(at: Date()) == 0)
        let estimate = try #require(ledger.estimate(currentWeekDayKeys: ["2026-09-08"]))
        #expect(estimate.observedTokens == 1440)
        #expect(estimate.pricedTokens == 1330)
        let duplicateAccepted = ledger.observeIncrement(sessionID: "root", summary: summary(counts(1400, 1100, 40)), slices: slices)
        #expect(!duplicateAccepted)
        #expect(ledger.records.first == frozen)
        #expect(try JSONDecoder().decode(APICostLedger.self, from: JSONEncoder().encode(ledger)).records == ledger.records)
    }

    @Test
    func independentChildrenDoNotInheritParentCounters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("child.jsonl")
        let fork = Date(timeIntervalSince1970: 1_783_987_200)
        let formatter = ISO8601DateFormatter()
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "child", "parent_thread_id": "parent", "timestamp": formatter.string(from: fork)]],
            ["type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            event(counts(100, 50, 10), at: formatter.string(from: fork.addingTimeInterval(10))),
            event(counts(500, 300, 20), at: formatter.string(from: fork.addingTimeInterval(20)))
        ]
        try lines.reduce(into: Data()) { data, value in
            data.append(try JSONSerialization.data(withJSONObject: value)); data.append(10)
        }.write(to: url)
        let descriptor = SessionUsageLogReader.descriptor(for: url)
        let parent = counts(1_000_000, 900_000, 10_000)
        let baseline = try #require(SessionUsageLogReader.resolvedChildBaseline(for: descriptor, parentBaseline: parent))
        #expect(baseline == .zero)
        let history = try #require(SessionUsageLogReader.history(for: descriptor, inheritedBaseline: baseline))
        #expect(history.summary.totalTokens == 520)
        #expect(history.slices.reduce(0) { $0 + $1.counts.totalTokens } == 520)
        #expect(SessionUsageLogReader.resolvedChildBaseline(for: descriptor, parentBaseline: nil) == nil)
    }

    @Test
    func parserKeepsAnomaliesSeparateFromNormalDailySlices() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("root.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "root"]],
            ["type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            event(counts(1000, 800, 20), at: "2026-09-07T01:00:00Z"),
            event(counts(1100, 1000, 30), at: "2026-09-07T01:01:00Z"),
            event(counts(1400, 1100, 40), at: "2026-09-07T01:02:00Z")
        ]
        try lines.reduce(into: Data()) { data, value in
            data.append(try JSONSerialization.data(withJSONObject: value)); data.append(10)
        }.write(to: url)
        let descriptor = SessionUsageLogReader.descriptor(for: url)
        let seed = SessionLogCursorState(completeLineCursor: 0, currentModel: "unknown", summary: summary(counts(1000, 800, 20)))
        let read = try #require(SessionUsageLogReader.incrementalRead(for: descriptor, previous: seed))
        #expect(read.slices.count == 2)
        #expect(read.slices.filter { $0.accountingNote != nil }.count == 1)
        var sum = TokenCounts.zero
        read.slices.forEach { sum.add($0.counts) }
        #expect(sum == counts(1400, 1100, 40).delta(since: counts(1000, 800, 20)))
    }

    private func counts(_ input: Int64, _ cache: Int64, _ output: Int64) -> TokenCounts {
        TokenCounts(inputTokens: input, cachedInputTokens: cache, outputTokens: output, totalTokens: input + output)
    }
    private func summary(_ c: TokenCounts) -> SessionTokenSummary {
        SessionTokenSummary(model: "gpt-6-astra", inputTokens: c.inputTokens, cachedInputTokens: c.cachedInputTokens,
                            outputTokens: c.outputTokens, totalTokens: c.totalTokens)
    }
    private func event(_ c: TokenCounts, at date: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": date, "payload": ["type": "token_count", "info": ["total_token_usage": [
            "input_tokens": c.inputTokens, "cached_input_tokens": c.cachedInputTokens,
            "output_tokens": c.outputTokens, "total_tokens": c.totalTokens
        ]]]]
    }
}
