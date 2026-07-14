import Foundation

enum SessionAPICostEstimator {
    private static let cache = SessionSummaryCache()
    private static let ledgerLock = NSLock()

    static func estimate(
        now: Date = Date(),
        ledgerURL: URL = APICostLedgerStore.defaultURL
    ) -> CodexAPICostEstimate? {
        let codexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let sessionRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let archivedRoot = codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        let allFiles = allSessionFiles(in: [sessionRoot, archivedRoot])
        let calendar = Calendar.current

        var observations: [SessionFileObservation] = []
        for fileURL in allFiles {
            guard let cached = cache.observation(for: fileURL) else { continue }
            observations.append(SessionFileObservation(
                sessionID: fileURL.lastPathComponent,
                summary: cached.summary,
                initialUsageDay: initialUsageDay(
                    for: fileURL,
                    modifiedAt: cached.modifiedAt,
                    calendar: calendar
                ),
                incrementalUsageDay: usageDay(for: cached.modifiedAt, calendar: calendar)
            ))
        }

        ledgerLock.lock()
        defer { ledgerLock.unlock() }

        do {
            let store = APICostLedgerStore(url: ledgerURL)
            var ledger = try store.load()
            var didChange = false
            for observation in observations {
                if ledger.observe(
                    sessionID: observation.sessionID,
                    summary: observation.summary,
                    initialUsageDay: observation.initialUsageDay,
                    incrementalUsageDay: observation.incrementalUsageDay,
                    price: APIModelPrice.price(for: observation.summary.model)
                ) {
                    didChange = true
                }
            }
            if didChange {
                try store.save(ledger)
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
}

private struct SessionFileObservation {
    let sessionID: String
    let summary: SessionTokenSummary
    let initialUsageDay: String
    let incrementalUsageDay: String
}

private struct FileSignature: Equatable {
    let size: Int
    let modifiedAt: Date
}

private struct CachedSessionSummary {
    let summary: SessionTokenSummary
    let modifiedAt: Date
}

private final class SessionSummaryCache: @unchecked Sendable {
    private struct Entry {
        let signature: FileSignature
        let summary: SessionTokenSummary?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func observation(for url: URL) -> CachedSessionSummary? {
        guard let signature = signature(for: url) else { return nil }
        let path = url.path

        lock.lock()
        let cached = entries[path]
        lock.unlock()
        if cached?.signature == signature {
            return cached?.summary.map {
                CachedSessionSummary(summary: $0, modifiedAt: signature.modifiedAt)
            }
        }

        let parsed = SessionSummaryReader.read(from: url, fileSize: signature.size)
        lock.lock()
        entries[path] = Entry(signature: signature, summary: parsed)
        lock.unlock()
        return parsed.map {
            CachedSessionSummary(summary: $0, modifiedAt: signature.modifiedAt)
        }
    }

    private func signature(for url: URL) -> FileSignature? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            let size = values.fileSize,
            let modifiedAt = values.contentModificationDate
        else { return nil }
        return FileSignature(size: size, modifiedAt: modifiedAt)
    }
}

private enum SessionSummaryReader {
    static func read(from url: URL, fileSize: Int) -> SessionTokenSummary? {
        if let summary = readTail(from: url, fileSize: fileSize, byteLimit: 131_072) {
            return summary
        }
        return readTail(from: url, fileSize: fileSize, byteLimit: 1_048_576)
    }

    private static func readTail(from url: URL, fileSize: Int, byteLimit: Int) -> SessionTokenSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let readSize = min(fileSize, byteLimit)
        do {
            try handle.seek(toOffset: UInt64(max(0, fileSize - readSize)))
            let data = try handle.readToEnd() ?? Data()
            var tokenUsage: [String: Any]?

            for rawLine in data.split(separator: 0x0A).reversed() {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                    let type = object["type"] as? String,
                    let payload = object["payload"] as? [String: Any]
                else { continue }

                if tokenUsage == nil,
                   type == "event_msg",
                   payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    tokenUsage = total
                    continue
                }

                if let usage = tokenUsage,
                   type == "turn_context",
                   let model = payload["model"] as? String {
                    let input = int64(usage["input_tokens"]) ?? 0
                    let cached = int64(usage["cached_input_tokens"]) ?? 0
                    let output = int64(usage["output_tokens"]) ?? 0
                    let total = int64(usage["total_tokens"]) ?? (input + output)
                    guard total > 0 else { return nil }
                    return SessionTokenSummary(
                        model: model,
                        inputTokens: input,
                        cachedInputTokens: cached,
                        outputTokens: output,
                        totalTokens: total
                    )
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
