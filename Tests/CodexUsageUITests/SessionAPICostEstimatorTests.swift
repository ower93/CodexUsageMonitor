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
}
