import Foundation

struct APIModelPrice: Codable, Equatable, Sendable {
    let version: String
    let displayName: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double

    // Standard API prices active when this app version was released.
    // When a price changes, keep the old version in existing ledger records and
    // return a new version here. Never edit persisted records in place.
    static func price(for rawModel: String) -> APIModelPrice? {
        let model = rawModel.lowercased()
        if model == "gpt-5.6-sol" || model.hasPrefix("gpt-5.6-sol-") {
            return APIModelPrice(
                version: "2026-07-13-standard",
                displayName: "GPT-5.6 Sol",
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30
            )
        }
        if model == "gpt-5.6-terra" || model.hasPrefix("gpt-5.6-terra-") {
            return APIModelPrice(
                version: "2026-07-13-standard",
                displayName: "GPT-5.6 Terra",
                inputPerMillion: 2.5,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 15
            )
        }
        if model == "gpt-5.6-luna" || model.hasPrefix("gpt-5.6-luna-") {
            return APIModelPrice(
                version: "2026-07-13-standard",
                displayName: "GPT-5.6 Luna",
                inputPerMillion: 1,
                cachedInputPerMillion: 0.1,
                outputPerMillion: 6
            )
        }
        if model == "gpt-5.5" || model.hasPrefix("gpt-5.5-") {
            return APIModelPrice(
                version: "2026-07-13-standard",
                displayName: "GPT-5.5",
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30
            )
        }
        if model == "gpt-5.4" || model.hasPrefix("gpt-5.4-") {
            return APIModelPrice(
                version: "2026-07-13-standard",
                displayName: "GPT-5.4",
                inputPerMillion: 2.5,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 15
            )
        }
        return nil
    }
}

struct SessionTokenSummary: Sendable {
    let model: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let totalTokens: Int64
}

struct APICostLedger: Codable, Sendable {
    private static let currentSchemaVersion = 2

    private(set) var schemaVersion: Int
    private(set) var checkpoints: [String: Checkpoint]
    private(set) var records: [Record]

    init() {
        schemaVersion = Self.currentSchemaVersion
        checkpoints = [:]
        records = []
    }

    var requiresRebuild: Bool {
        schemaVersion != Self.currentSchemaVersion
    }

    @discardableResult
    mutating func observe(
        sessionID: String,
        summary: SessionTokenSummary,
        initialUsageDay: String,
        incrementalUsageDay: String,
        price: APIModelPrice?,
        inheritedBaseline: TokenCounts? = nil
    ) -> Bool {
        let current = TokenCounts(summary: summary)
        let previousCheckpoint = checkpoints[sessionID]
        let previous = previousCheckpoint?.counts

        let delta: TokenCounts
        let usageDay: String
        if let previous {
            guard let incremental = current.delta(since: previous) else {
                // A rewritten or truncated log must not subtract or reprice
                // costs that were already frozen in the ledger.
                return false
            }
            delta = incremental
            usageDay = incrementalUsageDay
        } else {
            delta = current
            usageDay = initialUsageDay
        }

        checkpoints[sessionID] = Checkpoint(
            model: summary.model,
            counts: current,
            inheritedBaseline: inheritedBaseline ?? previousCheckpoint?.inheritedBaseline
        )

        guard delta.totalTokens > 0 else { return previous == nil }
        addRecord(
            sessionID: sessionID,
            usageDay: usageDay,
            model: summary.model,
            counts: delta,
            price: price
        )
        return true
    }

    @discardableResult
    mutating func replaceHistory(
        sessionID: String,
        history: SessionUsageHistory,
        inheritedBaseline: TokenCounts?
    ) -> Bool {
        records.removeAll { $0.sessionID == sessionID }
        checkpoints[sessionID] = Checkpoint(
            model: history.summary.model,
            counts: TokenCounts(summary: history.summary),
            inheritedBaseline: inheritedBaseline
        )

        for slice in history.slices where slice.counts.totalTokens > 0 {
            addRecord(
                sessionID: sessionID,
                usageDay: slice.usageDay,
                model: slice.model,
                counts: slice.counts,
                price: APIModelPrice.price(for: slice.model)
            )
        }
        return true
    }

    private mutating func addRecord(
        sessionID: String,
        usageDay: String,
        model: String,
        counts: TokenCounts,
        price: APIModelPrice?
    ) {
        let usd = price.map {
            SessionAPICostEstimator.estimatedUSD(price: $0, counts: counts)
        } ?? 0

        if let index = records.firstIndex(where: {
            $0.sessionID == sessionID
                && $0.usageDay == usageDay
                && $0.model == model
                && $0.price == price
        }) {
            records[index].add(counts, usd: usd)
        } else {
            records.append(Record(
                sessionID: sessionID,
                usageDay: usageDay,
                model: model,
                counts: counts,
                price: price,
                usd: usd
            ))
        }
    }

    func estimate(sevenDayKeys: Set<String>) -> CodexAPICostEstimate? {
        var sevenDayUSD = 0.0
        var lifetimeUSD = 0.0
        var pricedTokens: Int64 = 0
        var observedTokens: Int64 = 0
        var modelTokenTotals: [String: Int64] = [:]

        for record in records {
            observedTokens += record.counts.totalTokens
            lifetimeUSD += record.usd
            if sevenDayKeys.contains(record.usageDay) {
                sevenDayUSD += record.usd
            }
            if let price = record.price {
                pricedTokens += record.counts.totalTokens
                modelTokenTotals[price.displayName, default: 0] += record.counts.totalTokens
            }
        }

        guard observedTokens > 0 else { return nil }
        return CodexAPICostEstimate(
            sevenDayUSD: sevenDayUSD,
            lifetimeUSD: lifetimeUSD,
            pricedTokens: pricedTokens,
            observedTokens: observedTokens,
            modelNames: modelTokenTotals
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map(\.key)
        )
    }
}

extension APICostLedger {
    struct Checkpoint: Codable, Sendable {
        let model: String
        let counts: TokenCounts
        let inheritedBaseline: TokenCounts?
    }

    struct Record: Codable, Sendable {
        let sessionID: String
        let usageDay: String
        let model: String
        private(set) var counts: TokenCounts
        let price: APIModelPrice?
        private(set) var usd: Double

        mutating func add(_ delta: TokenCounts, usd additionalUSD: Double) {
            counts.add(delta)
            usd += additionalUSD
        }
    }
}

struct TokenCounts: Codable, Equatable, Sendable {
    private(set) var inputTokens: Int64
    private(set) var cachedInputTokens: Int64
    private(set) var outputTokens: Int64
    private(set) var totalTokens: Int64

    static let zero = TokenCounts(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        totalTokens: 0
    )

    init(summary: SessionTokenSummary) {
        inputTokens = max(0, summary.inputTokens)
        cachedInputTokens = min(max(0, summary.cachedInputTokens), inputTokens)
        outputTokens = max(0, summary.outputTokens)
        totalTokens = max(0, summary.totalTokens)
    }

    init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        totalTokens: Int64
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = min(max(0, cachedInputTokens), self.inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(0, totalTokens)
    }

    func delta(since previous: TokenCounts) -> TokenCounts? {
        guard
            inputTokens >= previous.inputTokens,
            cachedInputTokens >= previous.cachedInputTokens,
            outputTokens >= previous.outputTokens,
            totalTokens >= previous.totalTokens
        else { return nil }

        return TokenCounts(
            inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            totalTokens: totalTokens - previous.totalTokens
        )
    }

    func subtracting(_ baseline: TokenCounts) -> TokenCounts? {
        guard
            inputTokens >= baseline.inputTokens,
            cachedInputTokens >= baseline.cachedInputTokens,
            outputTokens >= baseline.outputTokens,
            totalTokens >= baseline.totalTokens
        else { return nil }

        return TokenCounts(
            inputTokens: inputTokens - baseline.inputTokens,
            cachedInputTokens: cachedInputTokens - baseline.cachedInputTokens,
            outputTokens: outputTokens - baseline.outputTokens,
            totalTokens: totalTokens - baseline.totalTokens
        )
    }

    mutating func add(_ other: TokenCounts) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        totalTokens += other.totalTokens
    }
}

struct APICostLedgerStore: Sendable {
    enum StoreError: Error {
        case corruptedLedger
    }

    let url: URL

    static var defaultURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexUsageMonitor", isDirectory: true)
            .appendingPathComponent("token-cost-ledger.json")
    }

    func load() throws -> APICostLedger {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return APICostLedger() }

        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: url),
           let ledger = try? decoder.decode(APICostLedger.self, from: data) {
            return ledger
        }

        let backupURL = backupURL
        if let data = try? Data(contentsOf: backupURL),
           let ledger = try? decoder.decode(APICostLedger.self, from: data) {
            return ledger
        }
        throw StoreError.corruptedLedger
    }

    func save(_ ledger: APICostLedger) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: url.path),
           let existingData = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(APICostLedger.self, from: existingData)) != nil {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: url, to: backupURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }

    @discardableResult
    func backupLegacyLedger(schemaVersion: Int) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupName = "token-cost-ledger-v\(schemaVersion)-backup-\(formatter.string(from: Date())).json"
        let migrationBackupURL = url.deletingLastPathComponent().appendingPathComponent(backupName)
        try fileManager.copyItem(at: url, to: migrationBackupURL)
        return migrationBackupURL
    }

    private var backupURL: URL {
        url.appendingPathExtension("backup")
    }
}
