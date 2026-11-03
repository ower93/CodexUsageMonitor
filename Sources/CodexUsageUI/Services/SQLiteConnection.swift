import Foundation
import SQLite3

/// A connection is owned by one synchronous operation, never shared with a
/// view or another queue. All user/source values use bound parameters.
final class SQLiteConnection {
    enum Value {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }
    enum Failure: Error { case open, statement, binding, step }
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw Failure.open
        }
        sqlite3_busy_timeout(handle, 1000)
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.statement }
    }

    func execute(_ sql: String, values: [Value] = []) throws {
        try statement(sql, values: values) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.step }
        }
    }

    func query<T>(_ sql: String, values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(sql, values: values) { stmt in
            var rows: [T] = []
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw Failure.step }
                rows.append(try row(stmt))
            }
        }
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: value)
    }

    static func data(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private func statement<T>(_ sql: String, values: [Value], body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw Failure.statement }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value): result = sqlite3_bind_text(pointer, index, value, -1, transient)
            case .integer(let value): result = sqlite3_bind_int64(pointer, index, value)
            case .real(let value): result = sqlite3_bind_double(pointer, index, value)
            case .blob(let value):
                result = value.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: result = sqlite3_bind_null(pointer, index)
            }
            guard result == SQLITE_OK else { throw Failure.binding }
        }
        return try body(pointer)
    }
}
