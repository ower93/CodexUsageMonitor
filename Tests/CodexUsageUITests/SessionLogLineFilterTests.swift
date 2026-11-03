import Foundation
import Testing
@testable import CodexUsageUI

struct SessionLogLineFilterTests {
    @Test func keepsRelevantEnvelopesAndRejectsLargeMessageBodies() {
        #expect(keeps(#"{"timestamp":"2026-10-06T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}"#))
        #expect(keeps(#"{"type":"session_meta","payload":{"id":"test"}}"#))
        #expect(keeps(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#))
        #expect(!keeps(#"{"type":"event_msg","payload":{"type":"agent_message","message":"ignore"}}"#))
        #expect(!keeps(#"{"type":"response_item","payload":{"type":"token_count","text":""# + String(repeating: "x", count: 1_000_000) + #""}}"#))
        #expect(!keeps(#"{ "timestamp" : "now", "type" : "response_item", "payload" : {} }"#))
        #expect(!keeps(#"{"timestamp":"2026-10-06T00:00:00Z","ordinal":123,"type":"response_item","payload":{"text":"ignore"}}"#))
        #expect(!keeps(#"{"ordinal":0,"flag":false,"type":"event_msg","payload":{"n":1,"type":"agent_message"}}"#))
        #expect(keeps(#"{"ordinal":123,"type":"event_msg","payload":{"type":"token_count","info":null}}"#))
    }

    @Test func unfamiliarHeadersFallBackRatherThanLosingUsage() {
        #expect(keeps(#"{"payload":{"type":"token_count"},"type":"event_msg"}"#))
        #expect(keeps(#"{"extra":{"type":"response_item"},"type":"event_msg","payload":{}}"#))
        #expect(keeps(#"{"type":"event_msg","payload":{"extra":123,"type":"token_count"}}"#))
        #expect(keeps(#"{"type":"event_msg","payload":{"message":"\"type\":\"agent_message\"","type":"token_count"}}"#))
        #expect(keeps(#"{"timestamp":""# + String(repeating: "x", count: 600) + #"","type":"event_msg"}"#))
        #expect(keeps(#"{"type":"\u0065vent_msg","payload":{"type":"token_count"}}"#))
        #expect(keeps(""))
    }

    private func keeps(_ line: String) -> Bool {
        line.withCString { SessionLogLineFilter.mayContainUsage(UnsafeBufferPointer(start: $0, count: line.utf8.count)) }
    }
}
