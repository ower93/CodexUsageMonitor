import Foundation

enum SessionAPICostEstimator {
    private static let cache = SessionSummaryCache()

    static func estimate(now: Date = Date()) -> CodexAPICostEstimate? {
        let codexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let sessionRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let archivedRoot = codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        let sevenDayFiles = sessionFilesForLastSevenDays(in: sessionRoot, now: now)
        let sevenDayPaths = Set(sevenDayFiles.map(\.path))
        let allFiles = allSessionFiles(in: [sessionRoot, archivedRoot])

        var sevenDay = CostAccumulator()
        var lifetime = CostAccumulator()
        for fileURL in allFiles {
            guard let summary = cache.summary(for: fileURL) else { continue }
            lifetime.add(summary)
            if sevenDayPaths.contains(fileURL.path) {
                sevenDay.add(summary)
            }
        }

        guard lifetime.observedTokens > 0 else { return nil }
        return CodexAPICostEstimate(
            sevenDayUSD: sevenDay.usd,
            lifetimeUSD: lifetime.usd,
            pricedTokens: lifetime.pricedTokens,
            observedTokens: lifetime.observedTokens,
            modelNames: lifetime.modelTokenTotals
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map(\.key)
        )
    }

    static func estimatedUSD(
        model: String,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64
    ) -> Double? {
        guard let price = APIModelPrice.price(for: model) else { return nil }
        let cachedInput = min(max(0, cachedInputTokens), max(0, inputTokens))
        let uncachedInput = max(0, inputTokens - cachedInput)
        let output = max(0, outputTokens)

        return Double(uncachedInput) / 1_000_000 * price.inputPerMillion
            + Double(cachedInput) / 1_000_000 * price.cachedInputPerMillion
            + Double(output) / 1_000_000 * price.outputPerMillion
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

    private static func sessionFilesForLastSevenDays(in root: URL, now: Date) -> [URL] {
        let calendar = Calendar.current
        let fileManager = FileManager.default
        var files: [URL] = []

        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)

            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files.append(contentsOf: contents.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }
}

private struct CostAccumulator {
    private(set) var usd = 0.0
    private(set) var pricedTokens: Int64 = 0
    private(set) var observedTokens: Int64 = 0
    private(set) var modelTokenTotals: [String: Int64] = [:]

    mutating func add(_ summary: SessionTokenSummary) {
        observedTokens += summary.totalTokens
        guard
            let price = APIModelPrice.price(for: summary.model),
            let sessionUSD = SessionAPICostEstimator.estimatedUSD(
                model: summary.model,
                inputTokens: summary.inputTokens,
                cachedInputTokens: summary.cachedInputTokens,
                outputTokens: summary.outputTokens
            )
        else { return }

        usd += sessionUSD
        pricedTokens += summary.totalTokens
        modelTokenTotals[price.displayName, default: 0] += summary.totalTokens
    }
}

private struct APIModelPrice {
    let displayName: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double

    // Official standard API list prices as of 2026-07-13.
    // https://developers.openai.com/api/docs/models/compare
    // https://developers.openai.com/api/docs/models/gpt-5.6-sol
    static func price(for rawModel: String) -> APIModelPrice? {
        let model = rawModel.lowercased()
        if model == "gpt-5.6-sol" || model.hasPrefix("gpt-5.6-sol-") {
            return APIModelPrice(
                displayName: "GPT-5.6 Sol",
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30
            )
        }
        if model == "gpt-5.6-terra" || model.hasPrefix("gpt-5.6-terra-") {
            return APIModelPrice(
                displayName: "GPT-5.6 Terra",
                inputPerMillion: 2.5,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 15
            )
        }
        if model == "gpt-5.6-luna" || model.hasPrefix("gpt-5.6-luna-") {
            return APIModelPrice(
                displayName: "GPT-5.6 Luna",
                inputPerMillion: 1,
                cachedInputPerMillion: 0.1,
                outputPerMillion: 6
            )
        }
        if model == "gpt-5.5" || model.hasPrefix("gpt-5.5-") {
            return APIModelPrice(
                displayName: "GPT-5.5",
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30
            )
        }
        if model == "gpt-5.4" || model.hasPrefix("gpt-5.4-") {
            return APIModelPrice(
                displayName: "GPT-5.4",
                inputPerMillion: 2.5,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 15
            )
        }
        return nil
    }
}

private struct SessionTokenSummary: Sendable {
    let model: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let totalTokens: Int64
}

private struct FileSignature: Equatable {
    let size: Int
    let modifiedAt: Date
}

private final class SessionSummaryCache: @unchecked Sendable {
    private struct Entry {
        let signature: FileSignature
        let summary: SessionTokenSummary?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func summary(for url: URL) -> SessionTokenSummary? {
        guard let signature = signature(for: url) else { return nil }
        let path = url.path

        lock.lock()
        let cached = entries[path]
        lock.unlock()
        if cached?.signature == signature {
            return cached?.summary
        }

        let parsed = SessionSummaryReader.read(from: url, fileSize: signature.size)
        lock.lock()
        entries[path] = Entry(signature: signature, summary: parsed)
        lock.unlock()
        return parsed
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
