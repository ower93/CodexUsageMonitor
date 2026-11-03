import Foundation

struct AnalyticsTotals: Sendable {
    var usd = 0.0
    var tokens: Int64 = 0
    var pricedTokens: Int64 = 0
    var validInputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var uncertainRows = 0
    var cacheShare: Double? { validInputTokens > 0 ? Double(cachedInputTokens) / Double(validInputTokens) : nil }
    var pricedShare: Double? { tokens > 0 ? Double(pricedTokens) / Double(tokens) : nil }

    mutating func include(_ record: APICostLedger.Record) {
        usd += record.usd
        tokens += record.counts.totalTokens
        outputTokens += record.counts.outputTokens
        if record.price != nil { pricedTokens += record.counts.totalTokens }
        if record.accountingNote == nil && record.counts.accountingIssue == nil {
            validInputTokens += record.counts.inputTokens
            cachedInputTokens += record.counts.cachedInputTokens
        } else { uncertainRows += 1 }
    }
}

struct AnalyticsDay: Identifiable, Sendable {
    let id: String
    let totals: AnalyticsTotals
}

struct AnalyticsChat: Identifiable, Sendable {
    let id: String
    let title: String
    let sessionIDs: Set<String>
    let totals: AnalyticsTotals
}

struct AnalyticsModel: Identifiable, Sendable {
    let id: String
    let totals: AnalyticsTotals
}

struct AnalyticsComparison: Sendable {
    let current: AnalyticsTotals
    let previous: AnalyticsTotals
    let completedDays: Int
    var costChangePercent: Double? { previous.usd > 0 ? (current.usd / previous.usd - 1) * 100 : nil }
}

struct AnalyticsResult: Sendable {
    let records: [AnalyticsRecord]
    let totals: AnalyticsTotals
    let days: [AnalyticsDay]
    let chats: [AnalyticsChat]
    let models: [AnalyticsModel]
    let range: AnalyticsDayRange
    let comparison: AnalyticsComparison?
}

enum AnalyticsEngine {
    static func summarize(_ data: AnalyticsData, filter: AnalyticsFilter, now: Date = Date(), calendar: Calendar = .current) -> AnalyticsResult {
        let range = filter.range(now: now, calendar: calendar)
        let base = data.records.filter { row in
            let record = row.value
            guard filter.model.isEmpty || record.model == filter.model else { return false }
            let root = data.rootID(for: record.sessionID)
            guard filter.familyID == nil || filter.familyID == root else { return false }
            let query = filter.search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return [record.sessionID, data.sessions[record.sessionID]?.title ?? "", data.sessions[root]?.title ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let records = base.filter { range.contains($0.value.usageDay) }
        var totals = AnalyticsTotals()
        var days: [String: AnalyticsTotals] = [:]
        var chats: [String: AnalyticsTotals] = [:]
        var members: [String: Set<String>] = [:]
        var models: [String: AnalyticsTotals] = [:]
        for row in records {
            let r = row.value
            let chat = filter.groupChildren ? data.rootID(for: r.sessionID) : r.sessionID
            totals.include(r)
            days[r.usageDay, default: AnalyticsTotals()].include(r)
            chats[chat, default: AnalyticsTotals()].include(r)
            members[chat, default: []].insert(r.sessionID)
            models[r.model, default: AnalyticsTotals()].include(r)
        }
        var chatRows = chats.map { id, totals in
            AnalyticsChat(id: id, title: title(for: id, in: data), sessionIDs: members[id] ?? [], totals: totals)
        }
        chatRows.sort { left, right in
            switch filter.sort {
            case .cost:
                if left.totals.usd != right.totals.usd { return filter.ascending ? left.totals.usd < right.totals.usd : left.totals.usd > right.totals.usd }
            case .tokens:
                if left.totals.tokens != right.totals.tokens { return filter.ascending ? left.totals.tokens < right.totals.tokens : left.totals.tokens > right.totals.tokens }
            case .title:
                if left.title != right.title { return filter.ascending ? left.title < right.title : left.title > right.title }
            }
            return left.id < right.id
        }
        return AnalyticsResult(records: records, totals: totals,
            days: days.keys.sorted().map { AnalyticsDay(id: $0, totals: days[$0]!) }, chats: chatRows,
            models: models.map { AnalyticsModel(id: $0.key, totals: $0.value) }.sorted {
                $0.totals.usd == $1.totals.usd ? $0.id < $1.id : $0.totals.usd > $1.totals.usd
            }, range: range, comparison: comparison(records: base, filter: filter, now: now, calendar: calendar))
    }

    static func title(for id: String, in data: AnalyticsData) -> String {
        let value = data.sessions[id]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Chat \(id.prefix(8))" : value
    }

    private static func comparison(records: [AnalyticsRecord], filter: AnalyticsFilter, now: Date, calendar: Calendar) -> AnalyticsComparison? {
        // Legacy records are daily buckets, not timestamped API calls. Comparing
        // today's partial bucket with a complete previous day would be false.
        // This-week comparisons therefore use equally many *completed* days.
        guard filter.period == .thisWeek else { return nil }
        let today = calendar.startOfDay(for: now)
        let count = (calendar.component(.weekday, from: today) + 5) % 7
        guard count > 0, let monday = calendar.date(byAdding: .day, value: -count, to: today),
              let previousMonday = calendar.date(byAdding: .day, value: -7, to: monday),
              let previousEnd = calendar.date(byAdding: .day, value: count - 1, to: previousMonday),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let currentRange = AnalyticsDayRange(start: AnalyticsFilter.day(monday, calendar), end: AnalyticsFilter.day(yesterday, calendar))
        let priorRange = AnalyticsDayRange(start: AnalyticsFilter.day(previousMonday, calendar), end: AnalyticsFilter.day(previousEnd, calendar))
        var current = AnalyticsTotals(), previous = AnalyticsTotals()
        for record in records {
            if currentRange.contains(record.value.usageDay) { current.include(record.value) }
            if priorRange.contains(record.value.usageDay) { previous.include(record.value) }
        }
        return AnalyticsComparison(current: current, previous: previous, completedDays: count)
    }
}
