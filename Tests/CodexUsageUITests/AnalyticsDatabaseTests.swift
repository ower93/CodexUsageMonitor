import Foundation
import Testing
@testable import CodexUsageUI

struct AnalyticsDatabaseTests {
    @Test
    func importsFrozenRecordsExactlyAndDoesNotDuplicateOnRescan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = AnalyticsDatabase(url: directory.appendingPathComponent("analytics.sqlite"))
        let ledger = makeLedger()
        let sessions = [AnalyticsSession(id: "root", title: "Private root title"),
                        AnalyticsSession(id: "child", parentID: "root", title: "Private child title")]
        #expect(try database.synchronize(ledger: ledger, sessions: sessions))
        #expect(try !database.synchronize(ledger: ledger, sessions: sessions))
        let data = try database.read()
        #expect(data.records.count == ledger.records.count)
        #expect(data.records.map(\.value) == ledger.records)
        #expect(data.records.reduce(0) { $0 + $1.value.usd } == ledger.records.reduce(0) { $0 + $1.usd })
        #expect(data.rootID(for: "child") == "root")
        #expect(data.importedAt != nil)
        #expect(try database.read(model: "'; DELETE FROM records; --").records.isEmpty)
        #expect(try database.read().records.count == 2)
        #expect(try database.read(startDay: "2026-10-06").records.count == 1)
        #expect(try database.read(endDay: "2026-10-05").records.count == 1)
    }

    @Test
    func failedImportRollsBackTheWholeTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = AnalyticsDatabase(url: directory.appendingPathComponent("analytics.sqlite"))
        let original = makeLedger()
        try database.synchronize(ledger: original, sessions: [])
        enum Abort: Error { case test }
        #expect(throws: Abort.self) {
            try database.synchronize(ledger: APICostLedger(), sessions: [], beforeCommit: { throw Abort.test })
        }
        #expect(try database.read().records.map(\.value) == original.records)
        // A changed payload with the same revision must not be mistaken for a
        // completed import after restoring an older ledger backup.
        #expect(try database.synchronize(ledger: APICostLedger(), sessions: []))
        #expect(try database.read().records.isEmpty)
    }

    @Test
    func rejectsUnknownFutureSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = AnalyticsDatabase(url: directory.appendingPathComponent("analytics.sqlite"))
        try database.synchronize(ledger: makeLedger(), sessions: [])
        let connection = try SQLiteConnection(url: database.url)
        try connection.execute("UPDATE metadata SET value='99' WHERE key='schema'")
        #expect(throws: AnalyticsDatabase.Failure.self) { try database.read() }
        #expect(throws: AnalyticsDatabase.Failure.self) { try database.synchronize(ledger: APICostLedger(), sessions: []) }
    }

    private func makeLedger() -> APICostLedger {
        var ledger = APICostLedger()
        let historical = APIModelPrice(version: "frozen-old", displayName: "Old Rate", inputPerMillion: 7,
                                       cachedInputPerMillion: 0.7, outputPerMillion: 21)
        ledger.observe(sessionID: "root", summary: SessionTokenSummary(model: "test", inputTokens: 1000,
            cachedInputTokens: 500, outputTokens: 100, totalTokens: 1100),
            initialUsageDay: "2026-10-05", incrementalUsageDay: "2026-10-05", price: historical)
        ledger.observe(sessionID: "child", summary: SessionTokenSummary(model: "unknown", inputTokens: 100,
            cachedInputTokens: 0, outputTokens: 10, totalTokens: 110),
            initialUsageDay: "2026-10-06", incrementalUsageDay: "2026-10-06", price: nil)
        return ledger
    }
}
