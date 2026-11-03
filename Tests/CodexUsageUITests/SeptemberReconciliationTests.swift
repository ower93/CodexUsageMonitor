import Foundation
import Testing
@testable import CodexUsageUI

/// Opt-in read-only replay of the previously captured audit. Private logs and
/// ledger snapshots are never fixtures committed to the repository.
struct SeptemberReconciliationTests {
    @Test
    func replayCapturedAuditWithoutWritingProductionData() throws {
        guard ProcessInfo.processInfo.environment["CODEX_USAGE_RECONCILE_AUDIT"] == "1" else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let auditRoot = root.appendingPathComponent("work/week-cost-diagnostic-20260908")
        let audit = try JSONDecoder().decode(Audit.self, from: Data(contentsOf: auditRoot.appendingPathComponent("readonly-repro.json")))
        let ledger = try APICostLedgerStore(url: auditRoot.appendingPathComponent("ledger-snapshot.json")).load()
        let index = try JSONDecoder().decode(SessionFileIndex.self, from: Data(contentsOf:
            root.appendingPathComponent("work/v2-implementation/backup-before-v2/session-file-index.json")))
        let original = try JSONEncoder().encode(ledger)
        var recoveredChildren = 0
        var acceptedRoots = 0
        var ambiguousSlices = 0
        for child in audit.missingChildren {
            let descriptor = try descriptor(for: child.session, in: index)
            let baseline = try #require(SessionUsageLogReader.resolvedChildBaseline(
                for: descriptor, parentBaseline: child.parentBaseline.value))
            #expect(baseline == .zero)
            let history = try #require(SessionUsageLogReader.history(for: descriptor, inheritedBaseline: baseline))
            #expect(history.summary.totalTokens > 0)
            #expect(history.slices.reduce(0) { $0 + $1.counts.totalTokens } == history.summary.totalTokens)
            recoveredChildren += 1
        }
        for stalled in audit.stalledRoots {
            let checkpoint = try #require(ledger.checkpoints[stalled.session])
            #expect(checkpoint.counts.totalTokens == stalled.checkpointTotal)
            let c = checkpoint.counts
            let seed = SessionLogCursorState(completeLineCursor: 0, currentModel: "unknown", summary:
                SessionTokenSummary(model: checkpoint.model, inputTokens: c.inputTokens, cachedInputTokens: c.cachedInputTokens,
                                    outputTokens: c.outputTokens, totalTokens: c.totalTokens))
            // Some captured counters occurred in a copied continuation, while
            // the original canonical file stopped at the old checkpoint. Replay
            // every matching history that reaches the audit's observed counter;
            // don't pick a random dictionary entry or discard a failed candidate.
            // These logs can have grown since September. This checks recovery
            // from the captured checkpoint, not a frozen September dollar total.
            let candidates = index.entries.keys.filter { $0.contains(stalled.session) }.sorted()
                .map { SessionUsageLogReader.descriptor(for: URL(fileURLWithPath: $0)) }
                .filter { $0.metadataResolved && $0.sessionID == stalled.session }
            var qualifyingHistories = 0
            var rootAccepted = true
            for descriptor in candidates {
                let read = try #require(SessionUsageLogReader.incrementalRead(
                    for: descriptor, previous: seed))
                let summary = try #require(read.state.summary)
                guard summary.totalTokens >= stalled.newRawTotal else { continue }
                qualifyingHistories += 1
                var trial = ledger
                let accepted = trial.observeIncrement(sessionID: stalled.session, summary: summary, slices: read.slices)
                if !accepted {
                    var sum = TokenCounts.zero
                    read.slices.forEach { sum.add($0.counts) }
                    print("RECONCILIATION_REJECTED session=\(stalled.session) checkpoint=\(checkpoint.counts) latest=\(TokenCounts(summary: summary)) sliced=\(sum)")
                }
                #expect(accepted)
                rootAccepted = rootAccepted && accepted
                ambiguousSlices += read.slices.filter { $0.accountingNote != nil }.count
                let beforeUSD = ledger.records.reduce(0) { $0 + $1.usd }
                let afterUSD = trial.records.reduce(0) { $0 + $1.usd }
                let addedUSD = read.slices.reduce(0.0) { sum, slice in
                    guard slice.accountingNote == nil, let price = APIModelPrice.price(for: slice.model) else { return sum }
                    return sum + SessionAPICostEstimator.estimatedUSD(price: price, counts: slice.counts)
                }
                #expect(abs(afterUSD - beforeUSD - addedUSD) < 0.000_001)
            }
            #expect(qualifyingHistories > 0, "A source history must reach the counter recorded in the audit")
            if qualifyingHistories > 0 && rootAccepted { acceptedRoots += 1 }
        }
        #expect(recoveredChildren == 11)
        #expect(acceptedRoots == 3)
        // Equality checked against the original object: all mutations above
        // were on in-memory copies. No ledger or Codex file was saved.
        #expect(try JSONDecoder().decode(APICostLedger.self, from: original).records == ledger.records)
        print("SEPTEMBER_RECONCILIATION children=\(recoveredChildren)/11 roots=\(acceptedRoots)/3 ambiguousSlices=\(ambiguousSlices) productionWritten=false")
    }

    private func descriptor(for session: String, in index: SessionFileIndex) throws -> SessionFileDescriptor {
        // A copied rollout can retain its parent's session_meta and filename
        // prefix. The captured audit refers to the canonical rollout ending in
        // -<session>.jsonl, not <parent>_<child>.jsonl. Resolve that exact file
        // deterministically, then independently verify its metadata identity.
        let candidates = index.entries.keys.filter {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                .hasSuffix("-\(session)")
        }.sorted()
            .map { SessionUsageLogReader.descriptor(for: URL(fileURLWithPath: $0)) }
            .filter { $0.metadataResolved && $0.sessionID == session }
        #expect(candidates.count == 1, "Audit expects one authoritative file per captured session")
        return try #require(candidates.first)
    }

    private struct Audit: Decodable {
        let missingChildren: [Child]
        let stalledRoots: [Root]
        struct Root: Decodable {
            let session: String
            let checkpointTotal: Int64
            let newRawTotal: Int64
        }
        struct Child: Decodable { let session: String; let parentBaseline: Counts }
        struct Counts: Decodable {
            let input: Int64; let cached: Int64; let output: Int64; let total: Int64
            var value: TokenCounts { TokenCounts(inputTokens: input, cachedInputTokens: cached, outputTokens: output, totalTokens: total) }
        }
    }
}
