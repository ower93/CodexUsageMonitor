import Foundation
import Testing
@testable import CodexUsageUI

struct JSONLineFileTests {
    @Test func chunkBoundariesFilteringAndPartialLinesKeepExactByteCursors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = 256 * 1024
        let token = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
        let message = #"{"type":"response_item","payload":{"text":""# + String(repeating: "中", count: chunk * 3) + #""}}"#
        // Arrange for a relevant envelope and its newline to cross read edges.
        let padding = String(repeating: " ", count: chunk - 3)
        let context = #"{"type":"turn_context","payload":{"model":"gpt-6-sol","padding":""#
            + String(repeating: "x", count: chunk * 2) + #""}}"#
        let lines = [padding, token, message, context, token]
        let complete = Data((lines.joined(separator: "\n") + "\n").utf8)
        let partial = Data(#"{"type":"event_msg","payload":{"type":"token_count""#.utf8)
        try (complete + partial).write(to: url)
        var unfiltered: [Data] = []
        let allCursor = try JSONLineFile.forEachCompleteLine(at: url, filterUsageLines: false) {
            unfiltered.append(Data(bytes: $0.baseAddress!, count: $0.count)); return true
        }
        var filtered: [Data] = []
        let cursor = try JSONLineFile.forEachCompleteLine(at: url) {
            filtered.append(Data(bytes: $0.baseAddress!, count: $0.count)); return true
        }
        #expect(cursor == UInt64(complete.count))
        #expect(cursor == allCursor)
        #expect(unfiltered == lines.map { Data($0.utf8) })
        #expect(filtered == [padding, token, context, token].map { Data($0.utf8) })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("}}\r\n".utf8))
        try handle.close()
        var appended: [Data] = []
        let after = try JSONLineFile.forEachCompleteLine(at: url, startingAt: cursor) {
            appended.append(Data(bytes: $0.baseAddress!, count: $0.count)); return true
        }
        #expect(appended == [partial + Data("}}\r".utf8)])
        #expect(after == UInt64(complete.count + partial.count + 4))
    }

    @Test func earlyStopReturnsEndOfAcceptedLineNotReadAheadPosition() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = "{\"type\":\"session_meta\"}\n"
        try Data((first + "{\"type\":\"turn_context\"}\n").utf8).write(to: url)
        let cursor = try JSONLineFile.forEachCompleteLine(at: url) { _ in false }
        #expect(cursor == UInt64(first.utf8.count))
    }
}
