import Foundation

/// Cheap envelope-only rejection before searching or decoding a potentially
/// multi-megabyte tool response. Unrecognized layouts always use the full parser.
/// This is a filter, not a JSON decoder or a source of token counts.
enum SessionLogLineFilter {
    static func mayContainUsage(_ line: UnsafeBufferPointer<CChar>) -> Bool {
        var prefix = Prefix(line)
        guard prefix.consume(0x7B), let type = prefix.stringField("type") else { return true }
        switch type {
        case "session_meta", "turn_context": return true
        case "event_msg":
            guard prefix.objectField("payload"), let event = prefix.stringField("type") else { return true }
            return event == "token_count"
        default: return false
        }
    }

    private struct Prefix {
        let bytes: UnsafeBufferPointer<CChar>
        let limit: Int
        var offset = 0
        init(_ bytes: UnsafeBufferPointer<CChar>) {
            self.bytes = bytes
            limit = min(bytes.count, 512)
        }

        mutating func consume(_ character: CChar) -> Bool {
            whitespace()
            guard offset < limit, bytes[offset] == character else { return false }
            offset += 1
            return true
        }

        mutating func stringField(_ name: String) -> String? {
            while offset < limit {
                _ = consume(0x2C)
                guard let key = string(), consume(0x3A) else { return nil }
                if key == name { return string() }
                guard skipScalar(), consume(0x2C) else { return nil }
            }
            return nil
        }

        mutating func objectField(_ name: String) -> Bool {
            while offset < limit {
                _ = consume(0x2C)
                guard let key = string(), consume(0x3A) else { return false }
                if key == name { return consume(0x7B) }
                guard skipScalar(), consume(0x2C) else { return false }
            }
            return false
        }

        private mutating func whitespace() {
            while offset < limit, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        private mutating func skipScalar() -> Bool {
            whitespace()
            guard offset < limit else { return false }
            if bytes[offset] == 0x22 { return string() != nil }
            let start = offset
            // Recent rollouts place a numeric ordinal before the envelope type.
            // Scalar header fields are safe to skip; nested objects/arrays are
            // intentionally left to the conservative full-parser fallback.
            while offset < limit {
                let byte = bytes[offset]
                if byte == 0x2C || byte == 0x7D || [9, 10, 13, 32].contains(byte) { break }
                guard (0x30...0x39).contains(byte) || [0x2D, 0x2B, 0x2E, 0x65, 0x45, 0x74, 0x72, 0x75, 0x66, 0x61, 0x6C, 0x73, 0x6E].contains(byte)
                else { return false }
                offset += 1
            }
            return offset > start && offset < limit
        }

        private mutating func string() -> String? {
            guard consume(0x22) else { return nil }
            let start = offset
            while offset < limit {
                let byte = bytes[offset]
                // Escaped/non-ASCII header strings take the conservative path.
                guard byte >= 0x20, byte != 0x5C else { return nil }
                if byte == 0x22 {
                    let value = String(decoding: UnsafeRawBufferPointer(bytes)[start..<offset], as: UTF8.self)
                    offset += 1
                    return value
                }
                offset += 1
            }
            return nil
        }
    }
}
