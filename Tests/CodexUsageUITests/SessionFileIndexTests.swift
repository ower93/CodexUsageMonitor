import Foundation
import Testing
@testable import CodexUsageUI

@Suite(.serialized)
struct SessionFileIndexTests {
    @Test
    func warmIndexServesUnchangedUnreadableLogWithoutOpeningItsBody() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_000)

        let initial = try #require(fixture.estimate())
        let storedIndex = fixture.indexStore.load()
        let entry = try #require(storedIndex.entries[fixture.indexKey])
        #expect(entry.completeLineCursor == entry.observedSize)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.sessionURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.sessionURL.path
            )
        }
        #expect(throws: (any Error).self) {
            _ = try Data(contentsOf: fixture.sessionURL)
        }

        let unchanged = try #require(fixture.estimate())
        #expect(unchanged.observedTokens == initial.observedTokens)
        #expect(fixture.indexStore.load() == storedIndex)
    }

    @Test
    func appendResumesAtCompleteLineAndDefersAPartialJSONLine() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_000)
        _ = try #require(fixture.estimate())

        let initialEntry = try #require(
            fixture.indexStore.load().entries[fixture.indexKey]
        )
        let appendedLine = try encodedLine(indexTokenCount(
            input: 1_500,
            timestamp: "2026-07-24T01:02:00.000Z"
        ))
        let split = appendedLine.count / 2
        try fixture.append(appendedLine.prefix(split))

        let partialEstimate = try #require(fixture.estimate())
        let partialEntry = try #require(
            fixture.indexStore.load().entries[fixture.indexKey]
        )
        #expect(partialEstimate.observedTokens == 1_000)
        #expect(partialEntry.completeLineCursor == initialEntry.completeLineCursor)
        #expect(partialEntry.observedSize > initialEntry.observedSize)

        try fixture.append(appendedLine.suffix(from: split))
        let completedEstimate = try #require(fixture.estimate())
        let completedEntry = try #require(
            fixture.indexStore.load().entries[fixture.indexKey]
        )

        #expect(completedEstimate.observedTokens == 1_500)
        #expect(completedEntry.completeLineCursor == completedEntry.observedSize)
    }

    @Test
    func truncationRebuildsCursorWithoutSubtractingFrozenLedgerHistory() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_500)
        _ = try #require(fixture.estimate())
        let before = try #require(
            fixture.indexStore.load().entries[fixture.indexKey]
        )

        try fixture.writeInitial(input: 200)
        let afterTruncation = try #require(fixture.estimate())
        let rebuilt = try #require(
            fixture.indexStore.load().entries[fixture.indexKey]
        )
        #expect(afterTruncation.observedTokens == 1_500)
        #expect(rebuilt.completeLineCursor == rebuilt.observedSize)
        #expect(
            rebuilt.identity != before.identity
                || rebuilt.observedSize != before.observedSize
                || rebuilt.modifiedAt != before.modifiedAt
        )

        try fixture.append(try encodedLine(indexTokenCount(
            input: 1_700,
            timestamp: "2026-07-24T01:03:00.000Z"
        )))
        let recovered = try #require(fixture.estimate())
        #expect(recovered.observedTokens == 1_700)
    }

    @Test
    func corruptIndexRebuildsWithoutRebuildingOrRepricingLedger() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 2_000)
        let initial = try #require(fixture.estimate())
        let ledgerBefore = try APICostLedgerStore(url: fixture.ledgerURL).load()

        try Data("{not-json".utf8).write(to: fixture.indexStore.url)
        let rebuilt = try #require(fixture.estimate())
        let ledgerAfter = try APICostLedgerStore(url: fixture.ledgerURL).load()

        #expect(rebuilt.observedTokens == initial.observedTokens)
        #expect(ledgerAfter.checkpoints == ledgerBefore.checkpoints)
        #expect(ledgerAfter.records == ledgerBefore.records)
        #expect(ledgerAfter.revision > ledgerBefore.revision)
        #expect(fixture.indexStore.load().entries[fixture.indexKey] != nil)
    }

    @Test
    func failedLedgerSaveDoesNotAdvanceIndexCursor() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_000)
        _ = try #require(fixture.estimate())
        let indexBefore = try Data(contentsOf: fixture.indexStore.url)

        try fixture.append(try encodedLine(indexTokenCount(
            input: 1_500,
            timestamp: "2026-07-24T01:04:00.000Z"
        )))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.ledgerURL.deletingLastPathComponent().path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.ledgerURL.deletingLastPathComponent().path
            )
        }

        #expect(fixture.estimate() == nil)
        let indexAfter = try Data(contentsOf: fixture.indexStore.url)
        #expect(indexAfter == indexBefore)
    }

    @Test
    func appendedEventsKeepTheirOwnUsageDayAndModelPrice() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_000)
        _ = try #require(fixture.estimate())

        try fixture.append(try encodedLine(indexTokenCount(
            input: 1_200,
            timestamp: "2026-07-24T15:59:00.000Z"
        )))
        try fixture.append(try encodedLine(indexTurnContext(
            model: "gpt-5.6-terra",
            timestamp: "2026-07-24T16:00:00.000Z"
        )))
        try fixture.append(try encodedLine(indexTokenCount(
            input: 1_600,
            timestamp: "2026-07-24T16:01:00.000Z"
        )))

        _ = try #require(fixture.estimate())
        let ledger = try APICostLedgerStore(url: fixture.ledgerURL).load()
        let sol = try #require(ledger.records.first {
            $0.sessionID == fixture.sessionID
                && $0.usageDay == "2026-07-24"
                && $0.model == "gpt-5.5"
        })
        let terra = try #require(ledger.records.first {
            $0.sessionID == fixture.sessionID
                && $0.usageDay == "2026-07-25"
                && $0.model == "gpt-5.6-terra"
        })

        #expect(sol.counts.totalTokens == 1_200)
        #expect(terra.counts.totalTokens == 400)
        #expect(sol.price?.displayName == "GPT-5.5")
        #expect(terra.price?.displayName == "GPT-5.6 Terra")
    }

    @Test
    func backupLedgerRevisionInvalidatesANewerIndex() throws {
        let fixture = try IndexFixture()
        defer { fixture.remove() }
        try fixture.writeInitial(input: 1_000)
        _ = try #require(fixture.estimate())
        try fixture.append(try encodedLine(indexTokenCount(
            input: 1_500,
            timestamp: "2026-07-24T01:04:00.000Z"
        )))
        _ = try #require(fixture.estimate())

        let currentLedger = try APICostLedgerStore(url: fixture.ledgerURL).load()
        let currentIndex = fixture.indexStore.load()
        #expect(currentLedger.revision == currentIndex.ledgerRevision)
        try Data("{corrupt-primary".utf8).write(to: fixture.ledgerURL)

        let recovered = try #require(fixture.estimate())
        let recoveredLedger = try APICostLedgerStore(url: fixture.ledgerURL).load()
        let recoveredIndex = fixture.indexStore.load()

        #expect(recovered.observedTokens == 1_500)
        #expect(recoveredLedger.revision == recoveredIndex.ledgerRevision)
        #expect(
            recoveredLedger.records.reduce(0) { $0 + $1.counts.totalTokens }
                == 1_500
        )
    }

    @Test
    func unresolvedForkRetriesWhenItsParentLogChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: true
        )
        let parentID = "00000000-0000-0000-0000-000000000020"
        let childID = "00000000-0000-0000-0000-000000000021"
        let parentURL = sessionRoot.appendingPathComponent(
            "rollout-2026-07-24T01-00-00-\(parentID).jsonl"
        )
        let childURL = sessionRoot.appendingPathComponent(
            "rollout-2026-07-24T01-02-00-\(childID).jsonl"
        )
        let ledgerURL = root.appendingPathComponent("ledger/token-cost-ledger.json")

        try writeIndexLines([
            indexSessionMeta(
                id: parentID,
                timestamp: "2026-07-24T01:00:00.000Z"
            ),
            indexTurnContext(
                model: "gpt-5.5",
                timestamp: "2026-07-24T01:00:01.000Z"
            )
        ], to: parentURL)
        try writeIndexLines([
            indexSessionMeta(
                id: childID,
                parentID: parentID,
                timestamp: "2026-07-24T01:02:00.000Z"
            ),
            indexTurnContext(
                model: "gpt-5.5",
                timestamp: "2026-07-24T01:02:01.000Z"
            ),
            indexTokenCount(
                input: 1_500,
                timestamp: "2026-07-24T01:03:00.000Z"
            )
        ], to: childURL)

        let first = SessionAPICostEstimator.estimate(
            ledgerURL: ledgerURL,
            sessionRoots: [sessionRoot]
        )
        #expect(first == nil)
        let firstIndex = SessionFileIndexStore(ledgerURL: ledgerURL).load()
        #expect(
            firstIndex.entries[SessionFileIndex.key(for: childURL)]?
                .baselineResolutionAttempted == true
        )

        let parentHandle = try FileHandle(forWritingTo: parentURL)
        try parentHandle.seekToEnd()
        try parentHandle.write(contentsOf: try encodedLine(indexTokenCount(
            input: 1_000,
            timestamp: "2026-07-24T01:01:00.000Z"
        )))
        try parentHandle.close()

        let recovered = try #require(SessionAPICostEstimator.estimate(
            ledgerURL: ledgerURL,
            sessionRoots: [sessionRoot]
        ))
        let ledger = try APICostLedgerStore(url: ledgerURL).load()
        let childCheckpoint = try #require(ledger.checkpoints[childID])

        #expect(recovered.observedTokens == 1_500)
        #expect(childCheckpoint.inheritedBaseline?.totalTokens == 1_000)
        #expect(
            ledger.records
                .filter { $0.sessionID == childID }
                .reduce(0) { $0 + $1.counts.totalTokens } == 500
        )
    }
}

private final class IndexFixture {
    let root: URL
    let sessionRoot: URL
    let sessionURL: URL
    let ledgerURL: URL
    let indexStore: SessionFileIndexStore

    let sessionID = "00000000-0000-0000-0000-000000000010"

    var indexKey: String {
        SessionFileIndex.key(for: sessionURL)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        sessionURL = sessionRoot.appendingPathComponent(
            "rollout-2026-07-24T01-00-00-\(sessionID).jsonl"
        )
        ledgerURL = root.appendingPathComponent("ledger/token-cost-ledger.json")
        indexStore = SessionFileIndexStore(ledgerURL: ledgerURL)
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ledgerURL.deletingLastPathComponent().path
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sessionURL.path
        )
        try? FileManager.default.removeItem(at: root)
    }

    func writeInitial(input: Int64) throws {
        var data = Data()
        data.append(try encodedLine(indexSessionMeta(
            id: sessionID,
            timestamp: "2026-07-24T01:00:00.000Z"
        )))
        data.append(try encodedLine(indexTurnContext(
            model: "gpt-5.5",
            timestamp: "2026-07-24T01:00:01.000Z"
        )))
        data.append(try encodedLine(indexTokenCount(
            input: input,
            timestamp: "2026-07-24T01:01:00.000Z"
        )))
        try data.write(to: sessionURL)
    }

    func append<T: DataProtocol>(_ bytes: T) throws {
        let handle = try FileHandle(forWritingTo: sessionURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
    }

    func estimate() -> CodexAPICostEstimate? {
        SessionAPICostEstimator.estimate(
            now: Date(timeIntervalSince1970: 1_774_512_000),
            ledgerURL: ledgerURL,
            sessionRoots: [sessionRoot]
        )
    }
}

private func encodedLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
}

private func indexSessionMeta(
    id: String,
    parentID: String? = nil,
    timestamp: String
) -> [String: Any] {
    var payload: [String: Any] = [
        "id": id,
        "timestamp": timestamp
    ]
    if let parentID {
        payload["forked_from_id"] = parentID
    }
    return [
        "timestamp": timestamp,
        "type": "session_meta",
        "payload": payload
    ]
}

private func indexTurnContext(model: String, timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "turn_context",
        "payload": ["model": model]
    ]
}

private func indexTokenCount(input: Int64, timestamp: String) -> [String: Any] {
    [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": input
                ]
            ]
        ]
    ]
}

private func writeIndexLines(
    _ objects: [[String: Any]],
    to url: URL
) throws {
    var data = Data()
    for object in objects {
        data.append(try encodedLine(object))
    }
    try data.write(to: url)
}
