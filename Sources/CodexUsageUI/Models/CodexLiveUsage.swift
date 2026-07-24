import Foundation

struct CodexLiveUsage: Sendable {
    let rateLimits: CodexRateLimitSnapshot
    let availableResetCount: Int
    let lifetimeTokens: Int64?
    let dailyUsage: [CodexDailyUsage]
    let recentThreads: [CodexThreadUsage]
    let apiCostEstimate: CodexAPICostEstimate?

    func replacingAPICostEstimate(_ estimate: CodexAPICostEstimate?) -> CodexLiveUsage {
        CodexLiveUsage(
            rateLimits: rateLimits,
            availableResetCount: availableResetCount,
            lifetimeTokens: lifetimeTokens,
            dailyUsage: dailyUsage,
            recentThreads: recentThreads,
            apiCostEstimate: estimate
        )
    }
}

struct CodexAPICostEstimate: Sendable {
    let sevenDayUSD: Double
    let lifetimeUSD: Double
    let pricedTokens: Int64
    let observedTokens: Int64
    let modelNames: [String]
}

struct CodexRateLimitSnapshot: Sendable {
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

struct CodexRateLimitWindow: Sendable {
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: Date?
}

struct CodexDailyUsage: Sendable {
    let startDate: String
    let tokens: Int64
}

struct CodexThreadUsage: Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let totalTokens: Int64?
}

extension UsageSnapshot {
    init(live: CodexLiveUsage, language: AppLanguage, now: Date = Date()) {
        let windows = [live.rateLimits.primary, live.rateLimits.secondary].compactMap { $0 }
        let periods = windows.enumerated().map { index, window in
            let remaining = max(0, min(100, Int((100 - window.usedPercent).rounded())))
            return UsagePeriod(
                id: index == 0 ? "primary" : "secondary",
                title: language.quotaTitle(durationMinutes: window.windowDurationMinutes, index: index),
                remainingPercent: remaining,
                resetText: language.resetDescription(for: window.resetsAt, now: now)
            )
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDayCutoff = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        let sevenDayTokens = live.dailyUsage.reduce(into: Int64(0)) { total, bucket in
            if let date = parser.date(from: bucket.startDate), date >= sevenDayCutoff {
                total += bucket.tokens
            }
        }

        let firstThreadTokens = live.recentThreads.first?.totalTokens
        let metrics = [
            UsageMetric(id: "current", value: Self.formatTokens(firstThreadTokens), label: language.metricCurrent),
            UsageMetric(id: "week", value: Self.formatTokens(sevenDayTokens), label: language.metricSevenDays),
            UsageMetric(id: "total", value: Self.formatTokens(live.lifetimeTokens), label: language.metricLifetime)
        ]

        let maximumThreadTokens = live.recentThreads.compactMap(\.totalTokens).max() ?? 0
        let recentTasks = live.recentThreads.prefix(3).map { thread in
            let progress: Double
            if let tokens = thread.totalTokens, maximumThreadTokens > 0 {
                progress = Double(tokens) / Double(maximumThreadTokens)
            } else {
                progress = 0
            }
            return RecentTask(
                id: thread.id,
                title: thread.title,
                time: Self.timeString(from: thread.updatedAt, language: language),
                tokenText: Self.formatTokens(thread.totalTokens),
                progress: progress
            )
        }

        self.init(
            planLabel: Self.planLabel(for: live.rateLimits.planType),
            periods: periods,
            metrics: metrics,
            recentTasks: recentTasks,
            apiCostEstimate: live.apiCostEstimate.map { estimate in
                APICostEstimateSnapshot(
                    sevenDayUSD: estimate.sevenDayUSD,
                    lifetimeUSD: estimate.lifetimeUSD,
                    coveragePercent: estimate.observedTokens > 0
                        ? Int((Double(estimate.pricedTokens) / Double(estimate.observedTokens) * 100).rounded())
                        : 0,
                    modelNames: estimate.modelNames
                )
            },
            availableResets: live.availableResetCount,
            updatedAt: now
        )
    }

    private static func planLabel(for planType: String?) -> String {
        switch planType?.lowercased() {
        case "pro": "PRO"
        case "plus": "PLUS"
        case "team": "TEAM"
        case "business": "BUSINESS"
        case "enterprise": "ENTERPRISE"
        case .some(let value): value.uppercased()
        case nil: "CODEX"
        }
    }

    private static func formatTokens(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        let value = Double(tokens)
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(tokens)
    }

    private static func timeString(from date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
