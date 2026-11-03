import Foundation
import Testing
@testable import CodexUsageUI

struct CurrentWeekCostTests {
    @Test(arguments: [1, 2, 7])
    func startsOnMondayRegardlessOfLocaleFirstWeekday(_ firstWeekday: Int) throws {
        var calendar = try calendar("Asia/Shanghai")
        calendar.firstWeekday = firstWeekday
        let monday = try date("2026-09-07T00:00:00+08:00")
        #expect(SessionAPICostEstimator.currentWeekDayKeys(now: monday, calendar: calendar)
            == ["2026-09-07"])

        let tuesday = try date("2026-09-08T14:30:00+08:00")
        #expect(SessionAPICostEstimator.currentWeekDayKeys(now: tuesday, calendar: calendar)
            == ["2026-09-07", "2026-09-08"])
    }

    @Test
    func sundayStaysInTheOldWeekUntilLocalMidnight() throws {
        let calendar = try calendar("Asia/Shanghai")
        let sunday = try date("2026-09-06T23:59:59+08:00")
        #expect(SessionAPICostEstimator.currentWeekDayKeys(now: sunday, calendar: calendar)
            == ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03",
                "2026-09-04", "2026-09-05", "2026-09-06"])
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: sunday.addingTimeInterval(1), calendar: calendar
        ) == ["2026-09-07"])
    }

    @Test
    func usesLocalTimeZoneInsteadOfUTCMidnight() throws {
        let now = try date("2026-09-06T16:00:00Z")
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: now, calendar: try calendar("Asia/Shanghai")
        ) == ["2026-09-07"])
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: now, calendar: try calendar("America/Los_Angeles")
        ) == ["2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03",
              "2026-09-04", "2026-09-05", "2026-09-06"])
    }

    @Test
    func crossesYearBoundaryWithoutDroppingDecemberDays() throws {
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: try date("2027-01-01T12:00:00+08:00"), calendar: try calendar("Asia/Shanghai")
        ) == ["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01"])
    }

    @Test
    func handlesSpringAndAutumnDaylightSavingTransitions() throws {
        let calendar = try calendar("America/New_York")
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: try date("2026-03-08T23:59:59-04:00"), calendar: calendar
        ) == ["2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05",
              "2026-03-06", "2026-03-07", "2026-03-08"])
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: try date("2026-03-09T00:00:00-04:00"), calendar: calendar
        ) == ["2026-03-09"])
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: try date("2026-11-01T23:59:59-05:00"), calendar: calendar
        ) == ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29",
              "2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(SessionAPICostEstimator.currentWeekDayKeys(
            now: try date("2026-11-02T00:00:00-05:00"), calendar: calendar
        ) == ["2026-11-02"])
    }

    @Test
    func refreshingAcrossWeeksChangesOnlyTheDisplayedSubtotal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = APICostLedgerStore(url: directory.appendingPathComponent("token-cost-ledger.json"))
        var ledger = APICostLedger()
        let price = try #require(APIModelPrice.price(for: "gpt-6-astra"))
        for (day, millions) in [("2026-09-06", 2), ("2026-09-07", 1), ("2026-09-08", 3),
                                ("2026-09-09", 4), ("2026-09-14", 5)] {
            let tokens = Int64(millions * 1_000_000)
            ledger.observe(
                sessionID: UUID().uuidString,
                summary: SessionTokenSummary(model: "gpt-6-astra", inputTokens: tokens,
                                             cachedInputTokens: 0, outputTokens: 0, totalTokens: tokens),
                initialUsageDay: day, incrementalUsageDay: day, price: price
            )
        }
        try store.save(ledger)
        let indexStore = SessionFileIndexStore(ledgerURL: store.url)
        try indexStore.save(SessionFileIndex(ledgerRevision: ledger.revision))
        let originalLedger = try Data(contentsOf: store.url)
        let originalIndex = try Data(contentsOf: indexStore.url)

        for (timestamp, expected) in [
            ("2026-09-06T23:59:59+08:00", 20.0),
            ("2026-09-07T00:00:00+08:00", 10.0),
            ("2026-09-08T18:00:00+08:00", 40.0),
            ("2026-09-14T00:00:00+08:00", 50.0)
        ] {
            let estimate = try #require(SessionAPICostEstimator.estimate(
                now: try date(timestamp), calendar: try calendar("Asia/Shanghai"),
                ledgerURL: store.url, sessionRoots: []
            ))
            #expect(estimate.currentWeekUSD == expected)
            #expect(estimate.lifetimeUSD == 150)
            #expect(try Data(contentsOf: store.url) == originalLedger)
            #expect(try Data(contentsOf: indexStore.url) == originalIndex)
        }
    }

    private func calendar(_ timeZone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        return calendar
    }

    private func date(_ timestamp: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: timestamp))
    }
}
