import Foundation

struct APIModelPrice: Codable, Equatable, Sendable {
    static let pricingSourceURL = "https://developers.openai.com/api/docs/pricing"

    let version: String
    let displayName: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double

    // Standard short-context API prices, verified 2026-09-07 at pricingSourceURL.
    // Cache-write premiums, long-context and service-tier surcharges are not
    // inferred from the cumulative input/cached-input/output counters.
    // When a price changes, keep the old version in existing ledger records and
    // return a new version here. Never edit persisted records in place.
    static func price(for rawModel: String) -> APIModelPrice? {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isGPT6Astra(model) {
            return APIModelPrice(
                version: "2026-09-07-standard",
                displayName: "GPT-6 Astra",
                inputPerMillion: 10,
                cachedInputPerMillion: 1,
                outputPerMillion: 50
            )
        }
        if model == "gpt-5.6-sol" || model.hasPrefix("gpt-5.6-sol-") {
            return APIModelPrice(
                version: "2026-09-07-standard",
                displayName: "GPT-5.6 Sol",
                inputPerMillion: 4,
                cachedInputPerMillion: 0.4,
                outputPerMillion: 20
            )
        }
        if model == "gpt-5.6-terra" || model.hasPrefix("gpt-5.6-terra-") {
            return APIModelPrice(
                version: "2026-09-07-standard",
                displayName: "GPT-5.6 Terra",
                inputPerMillion: 2,
                cachedInputPerMillion: 0.2,
                outputPerMillion: 12
            )
        }
        if model == "gpt-5.6-luna" || model.hasPrefix("gpt-5.6-luna-") {
            return APIModelPrice(
                version: "2026-09-07-standard",
                displayName: "GPT-5.6 Luna",
                inputPerMillion: 0.2,
                cachedInputPerMillion: 0.02,
                outputPerMillion: 1.2
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

    static func isGPT6Astra(_ rawModel: String) -> Bool {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the canonical ID and dated snapshots, not unknown Astra tiers
        // or a future GPT-6 variant whose price may differ.
        return model == "gpt-6-astra" || model.range(
            of: #"^gpt-6-astra-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
            options: .regularExpression
        ) != nil
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
    // Schema 3 marks the metadata-resolution fix. Schema migrations only update
    // structure; frozen price records and their stored USD values are retained.
    private static let currentSchemaVersion = 3

    private(set) var schemaVersion: Int
    private(set) var revision: UInt64
    private(set) var checkpoints: [String: Checkpoint]
    private(set) var records: [Record]

    init() {
        schemaVersion = Self.currentSchemaVersion
        revision = 0
        checkpoints = [:]
        records = []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case checkpoints
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        checkpoints = try container.decode(
            [String: Checkpoint].self,
            forKey: .checkpoints
        )
        records = try container.decode([Record].self, forKey: .records)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(checkpoints, forKey: .checkpoints)
        try container.encode(records, forKey: .records)
    }

    var requiresRebuild: Bool {
        schemaVersion != Self.currentSchemaVersion
    }

    mutating func migrateToCurrentSchemaPreservingHistory() -> LegacyPriceBook {
        var legacyPrices = LegacyPriceBook()
        let malformedSessionIDs = Set(
            checkpoints.keys.filter { Self.canonicalSessionID(from: $0) == nil }
        )

        for record in records
        where malformedSessionIDs.contains(record.sessionID)
            || Self.canonicalSessionID(from: record.sessionID) == nil {
            guard let canonicalID = Self.embeddedSessionID(in: record.sessionID) else {
                continue
            }
            legacyPrices.insert(
                price: record.price,
                sessionID: canonicalID,
                usageDay: record.usageDay,
                model: record.model
            )
        }

        // Schema 2 could key unresolved archived sessions by the complete
        // rollout filename. Those entries contain copied parent context and are
        // known-invalid billing history. Keep every UUID-keyed frozen record,
        // but let the affected sessions be rebuilt from their metadata while
        // reusing the historical price snapshots collected above.
        checkpoints = checkpoints.filter {
            Self.canonicalSessionID(from: $0.key) != nil
        }
        records.removeAll {
            Self.canonicalSessionID(from: $0.sessionID) == nil
        }
        schemaVersion = Self.currentSchemaVersion
        return legacyPrices
    }

    mutating func advanceRevision() {
        revision = revision == UInt64.max ? 1 : revision + 1
    }

    var hasUnpricedGPT6Usage: Bool {
        records.contains { $0.price == nil && APIModelPrice.isGPT6Astra($0.model) }
    }

    @discardableResult
    mutating func backfillUnpricedGPT6Usage(at date: Date) -> Int {
        let note = PricingBackfill(
            appliedAt: ISO8601DateFormatter().string(from: date),
            reason: "newly-supported-gpt-6-astra",
            sourceURL: APIModelPrice.pricingSourceURL
        )
        var count = 0
        for index in records.indices {
            let record = records[index]
            guard record.price == nil,
                  APIModelPrice.isGPT6Astra(record.model),
                  let price = APIModelPrice.price(for: record.model)
            else { continue }

            records[index] = Record(
                sessionID: record.sessionID,
                usageDay: record.usageDay,
                model: record.model,
                counts: record.counts,
                price: price,
                usd: SessionAPICostEstimator.estimatedUSD(price: price, counts: record.counts),
                pricingBackfill: note
            )
            count += 1
        }
        return count
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
    mutating func observeIncrement(
        sessionID: String,
        summary: SessionTokenSummary,
        slices: [SessionUsageSlice],
        inheritedBaseline: TokenCounts? = nil
    ) -> Bool {
        let current = TokenCounts(summary: summary)
        guard let previousCheckpoint = checkpoints[sessionID],
              let expectedDelta = current.delta(since: previousCheckpoint.counts)
        else {
            return false
        }

        var slicedDelta = TokenCounts.zero
        for slice in slices {
            slicedDelta.add(slice.counts)
        }
        guard slicedDelta == expectedDelta else {
            // Never advance the durable checkpoint unless every token in the
            // delta has an event-day and model attribution.
            return false
        }

        checkpoints[sessionID] = Checkpoint(
            model: summary.model,
            counts: current,
            inheritedBaseline: inheritedBaseline ?? previousCheckpoint.inheritedBaseline
        )
        for slice in slices where slice.counts.totalTokens > 0 {
            addRecord(
                sessionID: sessionID,
                usageDay: slice.usageDay,
                model: slice.model,
                counts: slice.counts,
                price: APIModelPrice.price(for: slice.model)
            )
        }
        return expectedDelta.totalTokens > 0
    }

    @discardableResult
    mutating func replaceHistory(
        sessionID: String,
        history: SessionUsageHistory,
        inheritedBaseline: TokenCounts?,
        legacyPrices: LegacyPriceBook = LegacyPriceBook()
    ) -> Bool {
        records.removeAll { $0.sessionID == sessionID }
        checkpoints[sessionID] = Checkpoint(
            model: history.summary.model,
            counts: TokenCounts(summary: history.summary),
            inheritedBaseline: inheritedBaseline
        )

        for slice in history.slices where slice.counts.totalTokens > 0 {
            let price = legacyPrices.price(
                sessionID: sessionID,
                usageDay: slice.usageDay,
                model: slice.model
            )
            addRecord(
                sessionID: sessionID,
                usageDay: slice.usageDay,
                model: slice.model,
                counts: slice.counts,
                price: price.wasRecorded
                    ? price.value
                    : APIModelPrice.price(for: slice.model)
            )
        }
        return true
    }

    private static func canonicalSessionID(from value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    private static func embeddedSessionID(in value: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = value.range(of: pattern, options: .regularExpression),
              let canonical = canonicalSessionID(from: String(value[range]))
        else { return nil }
        return canonical
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
                && $0.pricingBackfill == nil
        }) {
            records[index].add(counts, usd: usd)
        } else {
            records.append(Record(
                sessionID: sessionID,
                usageDay: usageDay,
                model: model,
                counts: counts,
                price: price,
                usd: usd,
                pricingBackfill: nil
            ))
        }
    }

    func estimate(currentWeekDayKeys: Set<String>) -> CodexAPICostEstimate? {
        var currentWeekUSD = 0.0
        var lifetimeUSD = 0.0
        var pricedTokens: Int64 = 0
        var observedTokens: Int64 = 0
        var modelTokenTotals: [String: Int64] = [:]

        for record in records {
            observedTokens += record.counts.totalTokens
            lifetimeUSD += record.usd
            if currentWeekDayKeys.contains(record.usageDay) {
                currentWeekUSD += record.usd
            }
            if let price = record.price {
                pricedTokens += record.counts.totalTokens
                modelTokenTotals[price.displayName, default: 0] += record.counts.totalTokens
            }
        }

        guard observedTokens > 0 else { return nil }
        return CodexAPICostEstimate(
            currentWeekUSD: currentWeekUSD,
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
    struct LegacyPriceBook {
        struct LookupResult {
            let wasRecorded: Bool
            let value: APIModelPrice?
        }

        private struct ExactKey: Hashable {
            let sessionID: String
            let usageDay: String
            let model: String
        }

        private struct ModelKey: Hashable {
            let sessionID: String
            let model: String
        }

        private struct Snapshot {
            let price: APIModelPrice?
        }

        private var exact: [ExactKey: Snapshot] = [:]
        private var byModel: [ModelKey: Snapshot] = [:]

        init() {}

        mutating func insert(
            price: APIModelPrice?,
            sessionID: String,
            usageDay: String,
            model: String
        ) {
            let exactKey = ExactKey(
                sessionID: sessionID,
                usageDay: usageDay,
                model: model
            )
            let modelKey = ModelKey(sessionID: sessionID, model: model)
            if exact[exactKey] == nil {
                exact[exactKey] = Snapshot(price: price)
            }
            if byModel[modelKey] == nil {
                byModel[modelKey] = Snapshot(price: price)
            }
        }

        func price(
            sessionID: String,
            usageDay: String,
            model: String
        ) -> LookupResult {
            let exactKey = ExactKey(
                sessionID: sessionID,
                usageDay: usageDay,
                model: model
            )
            if let snapshot = exact[exactKey] {
                return LookupResult(wasRecorded: true, value: snapshot.price)
            }
            let modelKey = ModelKey(sessionID: sessionID, model: model)
            if let snapshot = byModel[modelKey] {
                return LookupResult(wasRecorded: true, value: snapshot.price)
            }
            return LookupResult(wasRecorded: false, value: nil)
        }
    }

    struct Checkpoint: Codable, Equatable, Sendable {
        let model: String
        let counts: TokenCounts
        let inheritedBaseline: TokenCounts?
    }

    struct Record: Codable, Equatable, Sendable {
        let sessionID: String
        let usageDay: String
        let model: String
        private(set) var counts: TokenCounts
        let price: APIModelPrice?
        private(set) var usd: Double
        // Optional so existing schema-3 records decode unchanged. Backfilled
        // history stays separate from normally observed tokens on the same day.
        let pricingBackfill: PricingBackfill?

        mutating func add(_ delta: TokenCounts, usd additionalUSD: Double) {
            counts.add(delta)
            usd += additionalUSD
        }
    }

    struct PricingBackfill: Codable, Equatable, Sendable {
        let appliedAt: String
        let reason: String
        let sourceURL: String
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

    @discardableResult
    func backupBeforeGPT6Backfill(_ ledger: APICostLedger, at date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "token-cost-ledger-before-gpt6-backfill-\(formatter.string(from: date))-\(UUID().uuidString).json"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        // Encode the successfully loaded ledger, including when the main file
        // was corrupt and load() recovered its valid backup.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: destination, options: .atomic)
        return destination
    }

    private var backupURL: URL {
        url.appendingPathExtension("backup")
    }
}
