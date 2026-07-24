import Foundation

enum SessionAPICostEstimator {
    private static let ledgerLock = NSLock()

    static func estimate(
        now: Date = Date(),
        ledgerURL: URL = APICostLedgerStore.defaultURL,
        sessionRoots: [URL]? = nil
    ) -> CodexAPICostEstimate? {
        let roots: [URL]
        if let sessionRoots {
            roots = sessionRoots
        } else {
            let codexRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
            roots = [
                codexRoot.appendingPathComponent("sessions", isDirectory: true),
                codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        }
        let allFiles = allSessionFiles(in: roots)
        let calendar = Calendar.current

        ledgerLock.lock()
        defer { ledgerLock.unlock() }

        do {
            let store = APICostLedgerStore(url: ledgerURL)
            let indexStore = SessionFileIndexStore(ledgerURL: ledgerURL)
            var ledger = try store.load()
            var didMigrateLedger = false
            var legacyPrices = APICostLedger.LegacyPriceBook()

            if ledger.requiresRebuild {
                try store.backupLegacyLedger(schemaVersion: ledger.schemaVersion)
                legacyPrices = ledger.migrateToCurrentSchemaPreservingHistory()
                didMigrateLedger = true
            }

            let loadedIndex = indexStore.load()
            let indexMatchesLedger = !didMigrateLedger
                && loadedIndex.ledgerRevision == ledger.revision
            let savedIndex = indexMatchesLedger
                ? loadedIndex
                : SessionFileIndex(ledgerRevision: ledger.revision)
            var observations: [IndexedSessionObservation] = []
            var didChange = didMigrateLedger
            var indexDidChange = !indexMatchesLedger

            for url in allFiles {
                let previous = savedIndex.entries[SessionFileIndex.key(for: url)]
                guard let inspection = SessionFileIndexInspector.inspect(
                    url,
                    previousEntry: previous
                ) else { continue }

                let mustResolveMetadata = inspection.change == .rebuilt
                    || previous?.metadataResolved == false
                let descriptor = mustResolveMetadata
                    ? SessionUsageLogReader.descriptor(for: url)
                    : previous?.descriptor(url: url)
                        ?? SessionUsageLogReader.descriptor(for: url)
                let state = previous.map {
                    SessionLogCursorState(
                        completeLineCursor: $0.completeLineCursor,
                        currentModel: $0.currentModel,
                        summary: $0.summary
                    )
                }
                observations.append(IndexedSessionObservation(
                    inspection: inspection,
                    descriptor: descriptor,
                    state: state,
                    inheritedBaseline: previous?.inheritedBaseline,
                    baselineResolutionAttempted: previous?.baselineResolutionAttempted ?? false
                ))
            }

            // A transiently unreadable or partially-written session_meta line
            // must not be treated as a root session. Doing so would price the
            // copied history of a subagent and permanently inflate the ledger.
            let resolvedDescriptors = observations
                .map(\.descriptor)
                .filter(\.metadataResolved)
            let changedSessionIDs = Set(observations.compactMap { observation -> String? in
                let previous = observation.inspection.previousEntry
                if observation.inspection.change != .unchanged
                    || previous?.sessionID != observation.descriptor.sessionID
                    || previous?.metadataResolved != observation.descriptor.metadataResolved {
                    return observation.descriptor.sessionID
                }
                return nil
            })

            var inheritedBaselines: [String: TokenCounts] = [:]
            for observation in observations {
                if let checkpoint = ledger.checkpoints[observation.descriptor.sessionID],
                   let baseline = checkpoint.inheritedBaseline {
                    inheritedBaselines[observation.descriptor.sessionID] = baseline
                } else if let baseline = observation.inheritedBaseline {
                    inheritedBaselines[observation.descriptor.sessionID] = baseline
                }
            }

            let unresolvedForkIDs = Set<String>(observations.compactMap { observation -> String? in
                let descriptor = observation.descriptor
                guard descriptor.metadataResolved,
                      descriptor.parentSessionID != nil,
                      inheritedBaselines[descriptor.sessionID] == nil
                else { return nil }

                // Do not rescan unchanged JSONL files forever, but retry when
                // either the child or its parent changes.
                if observation.inspection.change == .unchanged,
                   observation.baselineResolutionAttempted,
                   let parentID = descriptor.parentSessionID,
                   !changedSessionIDs.contains(parentID) {
                    return nil
                }
                return descriptor.sessionID
            })
            if !unresolvedForkIDs.isEmpty {
                inheritedBaselines.merge(
                    SessionUsageLogReader.inheritedBaselines(
                        for: resolvedDescriptors,
                        childSessionIDs: unresolvedForkIDs
                    ),
                    uniquingKeysWith: { saved, _ in saved }
                )
            }

            for index in observations.indices {
                let descriptor = observations[index].descriptor
                guard descriptor.metadataResolved else { continue }
                let inheritedBaseline: TokenCounts
                if descriptor.parentSessionID != nil {
                    if unresolvedForkIDs.contains(descriptor.sessionID) {
                        observations[index].baselineResolutionAttempted = true
                        observations[index].inheritedBaseline =
                            inheritedBaselines[descriptor.sessionID]
                    }
                    guard let resolved = inheritedBaselines[descriptor.sessionID] else {
                        // A fork without a resolvable parent snapshot remains
                        // unpriced; billing copied context would inflate cost.
                        continue
                    }
                    inheritedBaseline = resolved
                } else {
                    inheritedBaseline = .zero
                }

                if ledger.checkpoints[descriptor.sessionID] == nil {
                    guard let read = SessionUsageLogReader.historyAndState(
                        for: descriptor,
                        inheritedBaseline: inheritedBaseline
                    ) else {
                        if observations[index].inspection.change != .unchanged {
                            observations[index].state = SessionUsageLogReader.warmState(
                                for: descriptor,
                                fileSize: observations[index].inspection.facts.size
                            )
                        }
                        continue
                    }
                    observations[index].state = read.state
                    ledger.replaceHistory(
                        sessionID: descriptor.sessionID,
                        history: read.history,
                        inheritedBaseline: descriptor.parentSessionID == nil
                            ? nil
                            : inheritedBaseline,
                        legacyPrices: legacyPrices
                    )
                    didChange = true
                    continue
                }

                let checkpoint = ledger.checkpoints[descriptor.sessionID]
                guard let checkpoint else { continue }
                let seed: SessionLogCursorState
                switch observations[index].inspection.change {
                case .unchanged:
                    // The ledger was saved before this cursor was committed, so
                    // an unchanged indexed file has nothing new to observe.
                    continue
                case .appended:
                    if let previousState = observations[index].state,
                       previousState.summary.map(TokenCounts.init(summary:))
                        == rawCounts(
                            checkpoint: checkpoint,
                            inheritedBaseline: inheritedBaseline
                        ) {
                        seed = previousState
                    } else {
                        seed = incrementalSeed(
                            checkpoint: checkpoint,
                            inheritedBaseline: inheritedBaseline
                        )
                    }
                case .rebuilt:
                    seed = incrementalSeed(
                        checkpoint: checkpoint,
                        inheritedBaseline: inheritedBaseline
                    )
                }

                guard let incremental = SessionUsageLogReader.incrementalRead(
                    for: descriptor,
                    previous: seed
                ) else { continue }
                observations[index].state = incremental.state

                guard let summary = incremental.state.summary,
                      let adjustedSummary = summary.subtracting(inheritedBaseline)
                else { continue }
                if ledger.observeIncrement(
                    sessionID: descriptor.sessionID,
                    summary: adjustedSummary,
                    slices: incremental.slices,
                    inheritedBaseline: descriptor.parentSessionID == nil
                        ? nil
                        : inheritedBaseline
                ) {
                    didChange = true
                }
            }

            var nextIndex = savedIndex
            let livePaths = Set(observations.map {
                SessionFileIndex.key(for: $0.inspection.url)
            })
            let removedPaths = Set(nextIndex.entries.keys).subtracting(livePaths)
            if !removedPaths.isEmpty {
                for path in removedPaths {
                    nextIndex.entries.removeValue(forKey: path)
                }
                indexDidChange = true
            }

            for observation in observations {
                let path = SessionFileIndex.key(for: observation.inspection.url)
                if observation.inspection.change == .unchanged,
                   var entry = savedIndex.entries[path] {
                    let oldEntry = entry
                    entry.sessionID = observation.descriptor.sessionID
                    entry.parentSessionID = observation.descriptor.parentSessionID
                    entry.forkedAt = observation.descriptor.forkedAt
                    entry.metadataResolved = observation.descriptor.metadataResolved
                    entry.inheritedBaseline = observation.inheritedBaseline
                    entry.baselineResolutionAttempted =
                        observation.baselineResolutionAttempted
                    if let state = observation.state {
                        entry.completeLineCursor = state.completeLineCursor
                        entry.currentModel = state.currentModel
                        entry.summaryModel = state.summary?.model
                        entry.summaryCounts = state.summary.map(TokenCounts.init(summary:))
                    }
                    if entry != oldEntry {
                        nextIndex.entries[path] = entry
                        indexDidChange = true
                    }
                    continue
                }

                guard let entry = SessionFileIndexInspector.makeEntry(
                    inspection: observation.inspection,
                    descriptor: observation.descriptor,
                    state: observation.state,
                    inheritedBaseline: observation.inheritedBaseline,
                    baselineResolutionAttempted: observation.baselineResolutionAttempted
                ) else { continue }
                if nextIndex.entries[path] != entry {
                    nextIndex.entries[path] = entry
                    indexDidChange = true
                }
            }

            if didChange || indexDidChange {
                // The cost ledger is the source of truth. Persist it before an
                // index cursor can acknowledge bytes as consumed.
                ledger.advanceRevision()
                nextIndex.ledgerRevision = ledger.revision
                try store.save(ledger)
                // The index is disposable. A failed cache write must not hide a
                // successfully persisted cost estimate.
                try? indexStore.save(nextIndex)
            }
            return ledger.estimate(sevenDayKeys: sevenDayKeys(now: now, calendar: calendar))
        } catch {
            // Do not recreate or reprice history when the durable ledger cannot
            // be read or written. The rest of the usage panel can still refresh.
            return nil
        }
    }

    static func estimatedUSD(
        model: String,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64
    ) -> Double? {
        guard let price = APIModelPrice.price(for: model) else { return nil }
        return estimatedUSD(
            price: price,
            counts: TokenCounts(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens,
                totalTokens: max(0, inputTokens) + max(0, outputTokens)
            )
        )
    }

    static func estimatedUSD(price: APIModelPrice, counts: TokenCounts) -> Double {
        let cachedInput = min(counts.cachedInputTokens, counts.inputTokens)
        let uncachedInput = max(0, counts.inputTokens - cachedInput)

        return Double(uncachedInput) / 1_000_000 * price.inputPerMillion
            + Double(cachedInput) / 1_000_000 * price.cachedInputPerMillion
            + Double(counts.outputTokens) / 1_000_000 * price.outputPerMillion
    }

    private static func allSessionFiles(in roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var filesByName: [String: URL] = [:]

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if filesByName[url.lastPathComponent] == nil {
                    filesByName[url.lastPathComponent] = url
                }
            }
        }
        return Array(filesByName.values)
    }

    private static func sevenDayKeys(now: Date, calendar: Calendar) -> Set<String> {
        let startOfToday = calendar.startOfDay(for: now)
        return Set((0..<7).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: -dayOffset, to: startOfToday).map {
                usageDay(for: $0, calendar: calendar)
            }
        })
    }

    private static func initialUsageDay(
        for fileURL: URL,
        modifiedAt: Date,
        calendar: Calendar
    ) -> String {
        let pathComponents = fileURL.pathComponents
        if let sessionsIndex = pathComponents.lastIndex(of: "sessions"),
           sessionsIndex + 3 < pathComponents.count,
           let year = Int(pathComponents[sessionsIndex + 1]),
           let month = Int(pathComponents[sessionsIndex + 2]),
           let day = Int(pathComponents[sessionsIndex + 3]),
           let result = validUsageDay(year: year, month: month, day: day, calendar: calendar) {
            return result
        }

        let fileName = fileURL.deletingPathExtension().lastPathComponent
        if let range = fileName.range(
            of: #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#,
            options: .regularExpression
        ) {
            let components = fileName[range].split(separator: "-").compactMap { Int($0) }
            if components.count == 3,
               let result = validUsageDay(
                   year: components[0],
                   month: components[1],
                   day: components[2],
                   calendar: calendar
               ) {
                return result
            }
        }

        return usageDay(for: modifiedAt, calendar: calendar)
    }

    private static func validUsageDay(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> String? {
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let validated = calendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == year, validated.month == month, validated.day == day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func usageDay(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func incrementalSeed(
        checkpoint: APICostLedger.Checkpoint,
        inheritedBaseline: TokenCounts
    ) -> SessionLogCursorState {
        let counts = rawCounts(
            checkpoint: checkpoint,
            inheritedBaseline: inheritedBaseline
        )
        return SessionLogCursorState(
            completeLineCursor: 0,
            currentModel: "unknown",
            summary: SessionTokenSummary(
                model: checkpoint.model,
                inputTokens: counts.inputTokens,
                cachedInputTokens: counts.cachedInputTokens,
                outputTokens: counts.outputTokens,
                totalTokens: counts.totalTokens
            )
        )
    }

    private static func rawCounts(
        checkpoint: APICostLedger.Checkpoint,
        inheritedBaseline: TokenCounts
    ) -> TokenCounts {
        var counts = checkpoint.counts
        counts.add(inheritedBaseline)
        return counts
    }
}

private extension SessionTokenSummary {
    func subtracting(_ baseline: TokenCounts) -> SessionTokenSummary? {
        guard let adjusted = TokenCounts(summary: self).subtracting(baseline) else {
            return nil
        }
        return SessionTokenSummary(
            model: model,
            inputTokens: adjusted.inputTokens,
            cachedInputTokens: adjusted.cachedInputTokens,
            outputTokens: adjusted.outputTokens,
            totalTokens: adjusted.totalTokens
        )
    }
}

private struct IndexedSessionObservation {
    let inspection: SessionFileIndexInspection
    let descriptor: SessionFileDescriptor
    var state: SessionLogCursorState?
    var inheritedBaseline: TokenCounts?
    var baselineResolutionAttempted: Bool
}
