import Foundation

extension AnalyticsData {
    /// Explicit demo mode only. Never a fallback for missing or failed sources.
    static func demo(now: Date = Date(), calendar: Calendar = .current) -> AnalyticsData {
        let sessions = [
            AnalyticsSession(id: "demo-build", title: "Build a native app"),
            AnalyticsSession(id: "demo-tests", parentID: "demo-build", title: "Review unit tests"),
            AnalyticsSession(id: "demo-research", title: "Research notes"),
            AnalyticsSession(id: "demo-docs", title: "Write documentation")
        ]
        var records: [AnalyticsRecord] = []
        for offset in 0..<21 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            for (index, session) in sessions.enumerated() {
                let model = ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra", "gpt-6-sol"][index]
                let input = Int64(100_000 + ((offset * 719 + index * 431) % 997) * 420)
                let output = Int64(12_000 + ((offset * 83 + index * 131) % 503) * 34)
                let counts = TokenCounts(inputTokens: input, cachedInputTokens: input * 7 / 10,
                                         outputTokens: output, totalTokens: input + output)
                let price = APIModelPrice.price(for: model)
                let record = APICostLedger.Record(sessionID: session.id, usageDay: AnalyticsFilter.day(date, calendar),
                    model: model, counts: counts, price: price,
                    usd: price.map { SessionAPICostEstimator.estimatedUSD(price: $0, counts: counts) } ?? 0, pricingBackfill: nil)
                records.append(AnalyticsRecord(id: Int64(records.count), value: record))
            }
        }
        return AnalyticsData(records: records, sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }), importedAt: now)
    }
}
