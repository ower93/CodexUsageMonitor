import Foundation
import Testing
@testable import CodexUsageUI

struct GPT6PricingTests {
    @Test(arguments: ["gpt-6-astra", "gpt-6-astra-2026-09-05", " GPT-6-ASTRA\n"])
    func pricesAstraInputCacheAndOutputSeparately(model: String) throws {
        let price = try #require(APIModelPrice.price(for: model))
        #expect(price.displayName == "GPT-6 Astra")
        #expect(price.version == "2026-09-07-standard")
        let cost = try #require(SessionAPICostEstimator.estimatedUSD(
            model: model,
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 100_000
        ))
        // 600k ordinary input ($6) + 400k cache hits ($0.40) + 100k output ($5).
        #expect(abs(cost - 11.40) < 0.000_001)
    }

    @Test(arguments: ["gpt-6", "gpt-6-astra-pro", "gpt-6-astra-mini", "gpt-6-astra-future"])
    func doesNotGuessPricesForOtherGPT6Variants(model: String) {
        #expect(APIModelPrice.price(for: model) == nil)
    }

    @Test
    func usesUpdatedGPT56RatesWithoutRepricingFrozenRecords() throws {
        let sol = try #require(APIModelPrice.price(for: "gpt-5.6-sol"))
        let terra = try #require(APIModelPrice.price(for: "gpt-5.6-terra"))
        let luna = try #require(APIModelPrice.price(for: "gpt-5.6-luna"))
        #expect([sol.inputPerMillion, sol.cachedInputPerMillion, sol.outputPerMillion] == [4, 0.4, 20])
        #expect([terra.inputPerMillion, terra.cachedInputPerMillion, terra.outputPerMillion] == [2, 0.2, 12])
        #expect([luna.inputPerMillion, luna.cachedInputPerMillion, luna.outputPerMillion] == [0.2, 0.02, 1.2])

        var ledger = APICostLedger()
        ledger.observe(
            sessionID: "sol-session", summary: summary(model: "gpt-5.6-sol", input: 1_000_000),
            initialUsageDay: "2026-07-24", incrementalUsageDay: "2026-07-24",
            price: APIModelPrice(version: "2026-07-13-standard", displayName: "GPT-5.6 Sol",
                                 inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30)
        )
        let frozen = ledger.records[0]
        ledger.observe(
            sessionID: "sol-session", summary: summary(model: "gpt-5.6-sol", input: 2_000_000),
            initialUsageDay: "2026-07-24", incrementalUsageDay: "2026-09-07", price: sol
        )
        #expect(ledger.records[0] == frozen)
        #expect(ledger.records[1].usd == 4)
        #expect(ledger.estimate(currentWeekDayKeys: ["2026-09-07"])?.lifetimeUSD == 9)
    }

    @Test
    func backfillsOnlyUnpricedAstraAndKeepsNewUsageSeparate() throws {
        var ledger = APICostLedger()
        for (id, model, price) in [
            ("pending", "gpt-6-astra", nil),
            ("unknown", "unpriced-model", nil),
            ("already-priced", "gpt-6-astra", APIModelPrice.price(for: "gpt-6-astra"))
        ] {
            ledger.observe(
                sessionID: id, summary: summary(model: model, input: 1_000_000),
                initialUsageDay: "2026-09-07", incrementalUsageDay: "2026-09-07", price: price
            )
        }
        let checkpoints = ledger.checkpoints
        let untouched = Array(ledger.records.dropFirst())
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-07T01:02:03Z"))
        #expect(ledger.backfillUnpricedGPT6Usage(at: date) == 1)
        #expect(ledger.checkpoints == checkpoints)
        #expect(Array(ledger.records.dropFirst()) == untouched)
        let backfilled = ledger.records[0]
        #expect(backfilled.usd == 10)
        #expect(backfilled.pricingBackfill?.appliedAt == "2026-09-07T01:02:03Z")
        #expect(backfilled.pricingBackfill?.sourceURL == APIModelPrice.pricingSourceURL)
        #expect(ledger.backfillUnpricedGPT6Usage(at: date.addingTimeInterval(60)) == 0)
        #expect(ledger.records[0] == backfilled)

        ledger.observe(
            sessionID: "pending", summary: summary(model: "gpt-6-astra", input: 1_100_000),
            initialUsageDay: "2026-09-07", incrementalUsageDay: "2026-09-07",
            price: APIModelPrice.price(for: "gpt-6-astra")
        )
        #expect(ledger.records[0] == backfilled)
        #expect(ledger.records.last?.usd == 1)
        #expect(ledger.records.last?.pricingBackfill == nil)
        let decoded = try JSONDecoder().decode(APICostLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded.records == ledger.records)
    }

    @Test
    func refreshBacksUpAndBackfillsWithoutRescanningOrDoubleCounting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = APICostLedgerStore(url: directory.appendingPathComponent("token-cost-ledger.json"))
        var ledger = APICostLedger()
        ledger.observe(
            sessionID: "pending", summary: summary(model: "gpt-6-astra", input: 1_000_000),
            initialUsageDay: "2026-09-06", incrementalUsageDay: "2026-09-06", price: nil
        )
        try store.save(ledger)
        let indexStore = SessionFileIndexStore(ledgerURL: store.url)
        try indexStore.save(SessionFileIndex(ledgerRevision: ledger.revision))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-07T01:02:03Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let result = try #require(SessionAPICostEstimator.estimate(
            now: now, calendar: calendar, ledgerURL: store.url, sessionRoots: []
        ))
        #expect(result.lifetimeUSD == 10)
        // Sunday's newly priced history stays in lifetime, not Monday's week.
        #expect(result.currentWeekUSD == 0)
        #expect(result.pricedTokens == 1_000_000)
        #expect(result.observedTokens == 1_000_000)
        #expect(result.modelNames == ["GPT-6 Astra"])
        let updated = try store.load()
        #expect(updated.revision == 1)
        #expect(indexStore.load().ledgerRevision == updated.revision)

        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("token-cost-ledger-before-gpt6-backfill-") }
        #expect(backups.count == 1)
        let backup = try APICostLedgerStore(url: #require(backups.first)).load()
        #expect(backup.records == ledger.records)
        #expect(backup.records[0].price == nil)
        _ = SessionAPICostEstimator.estimate(
            now: now, calendar: calendar, ledgerURL: store.url, sessionRoots: []
        )
        #expect(try store.load().records == updated.records)
        #expect(try store.load().revision == updated.revision)
    }

    private func summary(model: String, input: Int64) -> SessionTokenSummary {
        SessionTokenSummary(model: model, inputTokens: input, cachedInputTokens: 0,
                            outputTokens: 0, totalTokens: input)
    }
}
