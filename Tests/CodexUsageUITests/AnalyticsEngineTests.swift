import Foundation
import Testing
@testable import CodexUsageUI

struct AnalyticsEngineTests {
    private let now = Date(timeIntervalSince1970: 1_791_259_200) // 2026-10-06 00:00 UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func parentAndChildrenSumOnceAndDrillDownReconciles() {
        let data = fixture()
        var filter = AnalyticsFilter()
        filter.period = .allTime
        let grouped = AnalyticsEngine.summarize(data, filter: filter, now: now, calendar: utc)
        #expect(grouped.chats.count == 1)
        #expect(grouped.chats.first?.sessionIDs.count == 3)
        #expect(grouped.totals.usd == 28)
        #expect(grouped.chats.reduce(0) { $0 + $1.totals.usd } == grouped.totals.usd)
        filter.groupChildren = false
        filter.familyID = "root-private"
        let own = AnalyticsEngine.summarize(data, filter: filter, now: now, calendar: utc)
        #expect(own.chats.count == 3)
        #expect(own.chats.reduce(0) { $0 + $1.totals.tokens } == grouped.totals.tokens)
        #expect(own.chats.reduce(0) { $0 + $1.totals.usd } == grouped.totals.usd)
        #expect(own.days.reduce(0) { $0 + $1.totals.usd } == own.totals.usd)
        #expect(own.models.reduce(0) { $0 + $1.totals.usd } == own.totals.usd)
    }

    @Test
    func thisWeekComparisonExcludesPartialTodayOnBothSides() {
        let result = AnalyticsEngine.summarize(fixture(), filter: AnalyticsFilter(), now: now, calendar: utc)
        #expect(result.range.start == "2026-10-05")
        #expect(result.range.end == "2026-10-06")
        #expect(result.totals.usd == 20)
        #expect(result.comparison?.completedDays == 1)
        #expect(result.comparison?.current.usd == 10)
        #expect(result.comparison?.previous.usd == 8)
        #expect(result.comparison?.costChangePercent == 25)
        let monday = AnalyticsFilter.date("2026-10-05", utc)!
        #expect(AnalyticsEngine.summarize(fixture(), filter: AnalyticsFilter(), now: monday, calendar: utc).comparison == nil)
    }

    @Test
    func filtersModelsSearchAndCustomDatesBeforeAggregation() {
        var filter = AnalyticsFilter()
        filter.period = .custom
        filter.customStart = "2026-10-06"
        filter.customEnd = "2026-10-06"
        filter.model = "gpt-6-luna"
        filter.search = "private project"
        let result = AnalyticsEngine.summarize(fixture(), filter: filter, now: now, calendar: utc)
        #expect(result.records.count == 1)
        #expect(result.totals.usd == 4)
        filter.customStart = "bad date"
        let invalid = AnalyticsEngine.summarize(fixture(), filter: filter, now: now, calendar: utc)
        #expect(!invalid.range.isValid)
        #expect(invalid.records.isEmpty)
    }

    @Test
    func privacyCSVRemovesNamesAndIDsAndProtectsAgainstFormulas() {
        var data = fixture()
        data.sessions["root-private"]?.title = "=HYPERLINK(\"private\")"
        var filter = AnalyticsFilter()
        filter.period = .allTime
        let result = AnalyticsEngine.summarize(data, filter: filter, now: now, calendar: utc)
        let hidden = AnalyticsExport.csv(result, data: data)
        #expect(!hidden.contains("HYPERLINK"))
        #expect(!hidden.contains("root-private"))
        #expect(!hidden.contains("Private child"))
        #expect(hidden.contains("Chat "))
        let named = AnalyticsExport.csv(result, data: data, privacy: false)
        #expect(named.contains("\"'=HYPERLINK("))
        #expect(named.contains("frozen-test"))
    }

    @Test
    func cyclicParentMetadataCannotLoopOrSplitOneCycle() {
        var data = AnalyticsData()
        data.sessions = ["a": AnalyticsSession(id: "a", parentID: "b", title: ""),
                         "b": AnalyticsSession(id: "b", parentID: "c", title: ""),
                         "c": AnalyticsSession(id: "c", parentID: "b", title: "")]
        #expect(data.rootID(for: "a") == "b")
        #expect(data.rootID(for: "b") == "b")
        #expect(data.rootID(for: "c") == "b")
    }

    private func fixture() -> AnalyticsData {
        let price = APIModelPrice(version: "frozen-test", displayName: "Test", inputPerMillion: 1,
                                   cachedInputPerMillion: 0.1, outputPerMillion: 5)
        let source: [(String, String, String, Double)] = [
            ("root-private", "2026-09-28", "gpt-6-sol", 8),
            ("root-private", "2026-10-05", "gpt-6-sol", 10),
            ("child-private", "2026-10-06", "gpt-6-luna", 4),
            ("grandchild-private", "2026-10-06", "gpt-6-astra", 6)
        ]
        let records = source.enumerated().map { index, row in
            let count = Int64(row.3 * 1000)
            return AnalyticsRecord(id: Int64(index), value: APICostLedger.Record(sessionID: row.0, usageDay: row.1,
                model: row.2, counts: TokenCounts(inputTokens: count, cachedInputTokens: count / 2, outputTokens: 0, totalTokens: count),
                price: price, usd: row.3, pricingBackfill: nil))
        }
        return AnalyticsData(records: records, sessions: [
            "root-private": AnalyticsSession(id: "root-private", title: "Private project"),
            "child-private": AnalyticsSession(id: "child-private", parentID: "root-private", title: "Private child"),
            "grandchild-private": AnalyticsSession(id: "grandchild-private", parentID: "child-private", title: "Private grandchild")
        ])
    }
}
