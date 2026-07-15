import Foundation
import Testing
@testable import CodexUsageUI

struct SessionAPICostEstimatorTests {
    @Test
    func pricesCachedInputSeparatelyFromRegularInput() throws {
        let usd = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.5",
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 100_000
        ))

        // 600k regular input × $5/M + 400k cached input × $0.50/M
        // + 100k output × $30/M = $6.20.
        #expect(abs(usd - 6.20) < 0.000_001)
    }

    @Test
    func clampsCachedInputToTotalInput() throws {
        let usd = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            cachedInputTokens: 2_000_000,
            outputTokens: 0
        ))

        #expect(abs(usd - 0.50) < 0.000_001)
    }

    @Test
    func doesNotPriceUnknownModels() {
        let usd = SessionAPICostEstimator.estimatedUSD(
            model: "unpriced-model",
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 0
        )

        #expect(usd == nil)
    }

    @Test
    func freezesRecordedPricesAndUsesNewPriceOnlyForTokenDeltas() throws {
        let oldPrice = APIModelPrice(
            version: "old-price",
            displayName: "Test Model",
            inputPerMillion: 2,
            cachedInputPerMillion: 0.2,
            outputPerMillion: 10
        )
        let newPrice = APIModelPrice(
            version: "new-price",
            displayName: "Test Model",
            inputPerMillion: 8,
            cachedInputPerMillion: 0.8,
            outputPerMillion: 40
        )
        let initial = SessionTokenSummary(
            model: "test-model",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            totalTokens: 1_100_000
        )
        let increased = SessionTokenSummary(
            model: "test-model",
            inputTokens: 1_500_000,
            cachedInputTokens: 300_000,
            outputTokens: 200_000,
            totalTokens: 1_700_000
        )

        var ledger = APICostLedger()
        let recordedInitial = ledger.observe(
            sessionID: "session.jsonl",
            summary: initial,
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-13",
            price: oldPrice
        )
        #expect(recordedInitial)

        // Merely changing the catalog price must not reprice existing tokens.
        let changedWithoutNewTokens = ledger.observe(
            sessionID: "session.jsonl",
            summary: initial,
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-14",
            price: newPrice
        )
        #expect(!changedWithoutNewTokens)
        let unchanged = try #require(ledger.estimate(
            sevenDayKeys: ["2026-07-13", "2026-07-14"]
        ))
        #expect(abs(unchanged.lifetimeUSD - 2.64) < 0.000_001)

        let recordedIncrement = ledger.observe(
            sessionID: "session.jsonl",
            summary: increased,
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-14",
            price: newPrice
        )
        #expect(recordedIncrement)
        let updated = try #require(ledger.estimate(
            sevenDayKeys: ["2026-07-13", "2026-07-14"]
        ))

        // $2.64 at the old price + $7.28 for only the new token delta.
        #expect(abs(updated.lifetimeUSD - 9.92) < 0.000_001)
        #expect(ledger.records.compactMap(\.price?.version) == ["old-price", "new-price"])
    }

    @Test
    func doesNotBackfillPreviouslyUnpricedTokens() throws {
        let price = APIModelPrice(
            version: "first-supported-price",
            displayName: "Later Model",
            inputPerMillion: 1,
            cachedInputPerMillion: 0.1,
            outputPerMillion: 6
        )
        let initial = SessionTokenSummary(
            model: "later-model",
            inputTokens: 1_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            totalTokens: 1_000
        )
        let increased = SessionTokenSummary(
            model: "later-model",
            inputTokens: 2_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            totalTokens: 2_000
        )

        var ledger = APICostLedger()
        ledger.observe(
            sessionID: "later.jsonl",
            summary: initial,
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-13",
            price: nil
        )
        ledger.observe(
            sessionID: "later.jsonl",
            summary: increased,
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-14",
            price: price
        )

        let estimate = try #require(ledger.estimate(
            sevenDayKeys: ["2026-07-13", "2026-07-14"]
        ))
        #expect(estimate.observedTokens == 2_000)
        #expect(estimate.pricedTokens == 1_000)
        #expect(abs(estimate.lifetimeUSD - 0.001) < 0.000_001)
    }

    @Test
    func doesNotResetCheckpointWhenALogIsTemporarilyTruncated() throws {
        let price = APIModelPrice(
            version: "stable-price",
            displayName: "Stable Model",
            inputPerMillion: 1,
            cachedInputPerMillion: 0.1,
            outputPerMillion: 6
        )
        func summary(_ input: Int64) -> SessionTokenSummary {
            SessionTokenSummary(
                model: "stable-model",
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: input
            )
        }

        var ledger = APICostLedger()
        let recordedInitial = ledger.observe(
            sessionID: "rewritten.jsonl",
            summary: summary(1_000),
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-13",
            price: price
        )
        let recordedTruncation = ledger.observe(
            sessionID: "rewritten.jsonl",
            summary: summary(500),
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-14",
            price: price
        )
        let recordedRecovery = ledger.observe(
            sessionID: "rewritten.jsonl",
            summary: summary(1_200),
            initialUsageDay: "2026-07-13",
            incrementalUsageDay: "2026-07-14",
            price: price
        )

        #expect(recordedInitial)
        #expect(!recordedTruncation)
        #expect(recordedRecovery)

        let estimate = try #require(ledger.estimate(
            sevenDayKeys: ["2026-07-13", "2026-07-14"]
        ))
        #expect(estimate.observedTokens == 1_200)
        #expect(abs(estimate.lifetimeUSD - 0.0012) < 0.000_001)
    }

    @Test
    func persistsPriceSnapshotsInTheLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = APICostLedgerStore(
            url: directory.appendingPathComponent("token-cost-ledger.json")
        )
        let price = APIModelPrice(
            version: "persisted-price",
            displayName: "Persisted Model",
            inputPerMillion: 3,
            cachedInputPerMillion: 0.3,
            outputPerMillion: 18
        )
        var ledger = APICostLedger()
        ledger.observe(
            sessionID: "persisted.jsonl",
            summary: SessionTokenSummary(
                model: "persisted-model",
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: 1_000_000
            ),
            initialUsageDay: "2026-07-14",
            incrementalUsageDay: "2026-07-14",
            price: price
        )

        try store.save(ledger)
        let restored = try store.load()
        let estimate = try #require(restored.estimate(sevenDayKeys: ["2026-07-14"]))
        let json = try String(contentsOf: store.url, encoding: .utf8)

        #expect(abs(estimate.lifetimeUSD - 3) < 0.000_001)
        #expect(json.contains("persisted-price"))
        #expect(json.contains("inputPerMillion"))
    }

    @Test
    func subtractsForkedParentHistoryBeforePricingChildUsage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let parentID = "00000000-0000-0000-0000-000000000001"
        let childID = "00000000-0000-0000-0000-000000000002"
        let parentURL = directory.appendingPathComponent("parent.jsonl")
        let childURL = directory.appendingPathComponent("child.jsonl")

        try writeJSONLines([
            sessionMeta(id: parentID, timestamp: "2026-07-14T05:00:00.000Z"),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-07-14T05:01:00.000Z"),
            tokenCount(
                input: 2_707_855_640,
                cached: 2_542_441_216,
                output: 6_144_568,
                total: 2_714_000_208,
                timestamp: "2026-07-14T05:39:10.000Z"
            ),
            tokenCount(
                input: 2_708_000_000,
                cached: 2_542_500_000,
                output: 6_145_000,
                total: 2_714_145_000,
                timestamp: "2026-07-14T05:40:10.000Z"
            )
        ], to: parentURL)
        try writeJSONLines([
            sessionMeta(
                id: childID,
                parentID: parentID,
                timestamp: "2026-07-14T05:39:53.990Z"
            ),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-07-14T05:00:01.000Z"),
            tokenCount(
                input: 2_707_855_640,
                cached: 2_542_441_216,
                output: 6_144_568,
                total: 2_714_000_208,
                timestamp: "2026-07-14T05:39:10.000Z"
            ),
            turnContext(model: "gpt-5.6-sol", timestamp: "2026-07-14T05:40:00.000Z"),
            tokenCount(
                input: 2_715_067_046,
                cached: 2_549_075_712,
                output: 6_160_266,
                total: 2_721_227_312,
                timestamp: "2026-07-14T05:49:00.000Z"
            )
        ], to: childURL)

        let parent = SessionUsageLogReader.descriptor(for: parentURL)
        let child = SessionUsageLogReader.descriptor(for: childURL)
        let baseline = try #require(
            SessionUsageLogReader.inheritedBaselines(for: [parent, child])[childID]
        )
        let childEmbeddedBaseline = try #require(
            SessionUsageLogReader.inheritedBaselines(for: [child])[childID]
        )
        let history = try #require(SessionUsageLogReader.history(
            for: child,
            inheritedBaseline: baseline
        ))

        #expect(baseline.totalTokens == 2_714_000_208)
        #expect(childEmbeddedBaseline == baseline)
        #expect(history.summary.inputTokens == 7_211_406)
        #expect(history.summary.cachedInputTokens == 6_634_496)
        #expect(history.summary.outputTokens == 15_698)
        #expect(history.summary.totalTokens == 7_227_104)
        #expect(history.slices.reduce(0) { $0 + $1.counts.totalTokens } == 7_227_104)

        var ledger = APICostLedger()
        ledger.replaceHistory(
            sessionID: childID,
            history: history,
            inheritedBaseline: baseline
        )
        let estimate = try #require(ledger.estimate(sevenDayKeys: ["2026-07-14"]))
        #expect(abs(estimate.lifetimeUSD - 6.672_738) < 0.000_001)
    }

    @Test
    func knownJamesAndHypatiaDeltasMatchExpectedCosts() throws {
        let james = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.6-sol",
            inputTokens: 7_211_406,
            cachedInputTokens: 6_634_496,
            outputTokens: 15_698
        ))
        let hypatia = try #require(SessionAPICostEstimator.estimatedUSD(
            model: "gpt-5.6-sol",
            inputTokens: 51_233_047,
            cachedInputTokens: 47_064_832,
            outputTokens: 171_102
        ))

        #expect(abs(james - 6.672_738) < 0.000_001)
        #expect(abs(hypatia - 49.506_551) < 0.000_001)
    }

    @Test
    func backsUpSchemaOneLedgerBeforeRebuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = APICostLedgerStore(
            url: directory.appendingPathComponent("token-cost-ledger.json")
        )
        let encoded = try JSONEncoder().encode(APICostLedger())
        let schemaTwo = try #require(String(data: encoded, encoding: .utf8))
        let schemaOne = schemaTwo.replacingOccurrences(
            of: #""schemaVersion":2"#,
            with: #""schemaVersion":1"#
        )
        try Data(schemaOne.utf8).write(to: store.url)

        let legacy = try store.load()
        let savedBackupURL = try store.backupLegacyLedger(
            schemaVersion: legacy.schemaVersion
        )
        let backupURL = try #require(savedBackupURL)

        #expect(legacy.requiresRebuild)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backupURL.lastPathComponent.hasPrefix("token-cost-ledger-v1-backup-"))
    }
}

private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
    var data = Data()
    for object in objects {
        data.append(try JSONSerialization.data(withJSONObject: object))
        data.append(0x0A)
    }
    try data.write(to: url)
}

private func sessionMeta(
    id: String,
    parentID: String? = nil,
    timestamp: String
) -> [String: Any] {
    var payload: [String: Any] = [
        "id": id,
        "timestamp": timestamp
    ]
    if let parentID {
        payload["forked_from_id"] = parentID
    }
    return [
        "timestamp": timestamp,
        "type": "session_meta",
        "payload": payload
    ]
}

private func turnContext(model: String, timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "turn_context",
        "payload": ["model": model]
    ]
}

private func tokenCount(
    input: Int64,
    cached: Int64,
    output: Int64,
    total: Int64,
    timestamp: String
) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "total_tokens": total
                ]
            ]
        ]
    ]
}
