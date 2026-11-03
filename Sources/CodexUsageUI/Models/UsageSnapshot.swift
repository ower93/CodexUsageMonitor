import Foundation

struct UsagePeriod: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    var remainingPercent: Int
    let resetText: String
}

struct UsageMetric: Identifiable, Codable, Sendable {
    let id: String
    let value: String
    let label: String
}

struct RecentTask: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let time: String
    let tokenText: String
    let progress: Double
}

struct APICostEstimateSnapshot: Codable, Sendable {
    let currentWeekUSD: Double
    let lifetimeUSD: Double
    let coveragePercent: Int
    let modelNames: [String]
    var hasPricedUsage = true
    var currentWeekHasPricedUsage = true
}

struct UsageSnapshot: Codable, Sendable {
    var planLabel: String
    var periods: [UsagePeriod]
    var metrics: [UsageMetric]
    var recentTasks: [RecentTask]
    var apiCostEstimate: APICostEstimateSnapshot?
    var availableResets: Int?
    var updatedAt: Date?

    static func empty(language: AppLanguage) -> UsageSnapshot {
        UsageSnapshot(planLabel: "CODEX", periods: [], metrics: [
            UsageMetric(id: "current", value: "—", label: language.metricCurrent),
            UsageMetric(id: "week", value: "—", label: language.metricSevenDays),
            UsageMetric(id: "total", value: "—", label: language.metricLifetime)
        ], recentTasks: [], apiCostEstimate: nil, availableResets: nil, updatedAt: nil)
    }

    static func preview(language: AppLanguage, now: Date = Date()) -> UsageSnapshot {
        let taskCopy = language.previewTasks
        let demo = AnalyticsData.demo(now: now)
        let week = AnalyticsEngine.summarize(demo, filter: AnalyticsFilter(), now: now)
        var all = AnalyticsFilter()
        all.period = .allTime
        let lifetime = AnalyticsEngine.summarize(demo, filter: all, now: now)
        return UsageSnapshot(
            planLabel: "PRO",
            periods: [
                UsagePeriod(
                    id: "five-hour",
                    title: language.quotaTitle(durationMinutes: 300, index: 0),
                    remainingPercent: 78,
                    resetText: language.resetDescription(for: now.addingTimeInterval(3 * 3600), now: now)
                ),
                UsagePeriod(
                    id: "seven-day",
                    title: language.quotaTitle(durationMinutes: 10_080, index: 1),
                    remainingPercent: 72,
                    resetText: language.resetDescription(for: now.addingTimeInterval(5 * 86400), now: now)
                )
            ],
            metrics: [
                UsageMetric(id: "current", value: "24.80M", label: language.metricCurrent),
                UsageMetric(id: "week", value: "1.26B", label: language.metricSevenDays),
                UsageMetric(id: "total", value: "3.84B", label: language.metricLifetime)
            ],
            recentTasks: [
                RecentTask(
                    id: "hidden-1",
                    title: taskCopy[0].title,
                    time: taskCopy[0].time,
                    tokenText: taskCopy[0].token,
                    progress: 0.88
                ),
                RecentTask(
                    id: "hidden-2",
                    title: taskCopy[1].title,
                    time: taskCopy[1].time,
                    tokenText: taskCopy[1].token,
                    progress: 0.62
                ),
                RecentTask(
                    id: "hidden-3",
                    title: taskCopy[2].title,
                    time: taskCopy[2].time,
                    tokenText: taskCopy[2].token,
                    progress: 0.35
                )
            ],
            apiCostEstimate: APICostEstimateSnapshot(
                currentWeekUSD: week.totals.usd,
                lifetimeUSD: lifetime.totals.usd,
                coveragePercent: Int((lifetime.totals.pricedShare ?? 0) * 100),
                modelNames: lifetime.models.map(\.id)
            ),
            availableResets: 2,
            updatedAt: now
        )
    }
}
