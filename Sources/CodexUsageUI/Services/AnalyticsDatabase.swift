import CryptoKit
import Foundation
import SQLite3

/// Transactional query projection of the frozen ledger. Original JSON remains
/// the recovery/audit source; SQL never recalculates historical prices or USD.
struct AnalyticsDatabase: Sendable {
    enum Failure: Error { case unsupportedSchema }
    let url: URL
    static var defaultURL: URL { APICostLedgerStore.defaultURL.deletingLastPathComponent().appendingPathComponent("analytics.sqlite") }

    @discardableResult
    func synchronize(
        ledger: APICostLedger,
        sessions: [AnalyticsSession],
        now: Date = Date(),
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let connection = try SQLiteConnection(url: url)
        try connection.executeScript("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS records (
          id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, usage_day TEXT NOT NULL,
          model TEXT NOT NULL, usd REAL NOT NULL, tokens INTEGER NOT NULL,
          priced INTEGER NOT NULL, payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS records_day_model ON records(usage_day, model);
        CREATE INDEX IF NOT EXISTS records_session_day ON records(session_id, usage_day);
        CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT NOT NULL);
        """)
        try Self.validateSchema(connection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sortedSessions = sessions.sorted { $0.id < $1.id }
        var digest = SHA256()
        digest.update(data: try encoder.encode(ledger))
        digest.update(data: try encoder.encode(sortedSessions))
        let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let previous = try connection.query("SELECT value FROM metadata WHERE key='fingerprint'") { SQLiteConnection.text($0, 0) }.first ?? nil
        guard previous != fingerprint else { return false }

        try connection.executeScript("BEGIN IMMEDIATE;")
        do {
            try connection.executeScript("DELETE FROM records; DELETE FROM sessions;")
            for (id, record) in ledger.records.enumerated() {
                try Task.checkCancellation()
                try connection.execute("INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?, ?)", values: [
                    .integer(Int64(id)), .text(record.sessionID), .text(record.usageDay), .text(record.model),
                    .real(record.usd), .integer(record.counts.totalTokens), .integer(record.price == nil ? 0 : 1),
                    .blob(try encoder.encode(record))
                ])
            }
            for session in sortedSessions {
                try connection.execute("INSERT INTO sessions VALUES (?, ?, ?)", values: [
                    .text(session.id), session.parentID.map(SQLiteConnection.Value.text) ?? .null, .text(session.title)
                ])
            }
            for (key, value) in ["fingerprint": fingerprint, "schema": "1", "ledgerRevision": String(ledger.revision),
                                 "importedAt": String(now.timeIntervalSince1970)] {
                try connection.execute("INSERT OR REPLACE INTO metadata VALUES (?, ?)", values: [.text(key), .text(value)])
            }
            try beforeCommit?()
            try Task.checkCancellation()
            try connection.executeScript("COMMIT;")
            return true
        } catch {
            try? connection.executeScript("ROLLBACK;")
            throw error
        }
    }

    func read(startDay: String? = nil, endDay: String? = nil, model: String? = nil) throws -> AnalyticsData {
        guard FileManager.default.fileExists(atPath: url.path) else { return AnalyticsData() }
        let connection = try SQLiteConnection(url: url, readOnly: true)
        try Self.validateSchema(connection)
        // Keep records and metadata from one committed import during a scan.
        try connection.executeScript("BEGIN;")
        defer { try? connection.executeScript("ROLLBACK;") }
        var conditions = [String]()
        var values = [SQLiteConnection.Value]()
        if let startDay { conditions.append("usage_day >= ?"); values.append(.text(startDay)) }
        if let endDay { conditions.append("usage_day <= ?"); values.append(.text(endDay)) }
        if let model { conditions.append("model = ?"); values.append(.text(model)) }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let records = try connection.query("SELECT id, payload FROM records" + filter + " ORDER BY usage_day, id", values: values) { statement in
            AnalyticsRecord(id: sqlite3_column_int64(statement, 0), value: try JSONDecoder().decode(
                APICostLedger.Record.self, from: SQLiteConnection.data(statement, 1)))
        }
        let sessions = try connection.query("SELECT id, parent_id, title FROM sessions") { statement in
            AnalyticsSession(id: SQLiteConnection.text(statement, 0) ?? "", parentID: SQLiteConnection.text(statement, 1),
                             title: SQLiteConnection.text(statement, 2) ?? "")
        }
        let imported = try connection.query("SELECT value FROM metadata WHERE key='importedAt'") { SQLiteConnection.text($0, 0) }.first ?? nil
        return AnalyticsData(records: records, sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }),
                             importedAt: imported.flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
    }

    private static func validateSchema(_ connection: SQLiteConnection) throws {
        let version = try connection.query("SELECT value FROM metadata WHERE key='schema'") { SQLiteConnection.text($0, 0) }.first ?? nil
        guard version == nil || version == "1" else { throw Failure.unsupportedSchema }
    }
}

enum CodexSessionNames {
    /// The title-only index avoids reading prompts or opening Codex's state DB.
    static func read(at root: URL = CodexEnvironment.home()) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 10) {
            if Task.isCancelled { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, let title = object["thread_name"] as? String else { continue }
            names[id] = title
        }
        return names
    }
}
