import Foundation

struct CodexLiveUsage: Sendable {
    let rateLimits: CodexRateLimitSnapshot
    let availableResetCount: Int
    let lifetimeTokens: Int64?
    let dailyUsage: [CodexDailyUsage]
    let recentThreads: [CodexThreadUsage]
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
    init(live: CodexLiveUsage, now: Date = Date()) {
        let windows = [live.rateLimits.primary, live.rateLimits.secondary].compactMap { $0 }
        let periods = windows.enumerated().map { index, window in
            let duration = window.windowDurationMinutes
            let title: String
            switch duration {
            case 300:
                title = "5 小时额度"
            case 10_080:
                title = "7 天额度"
            case .some(let minutes) where minutes % 1_440 == 0:
                title = "\(minutes / 1_440) 天额度"
            case .some(let minutes) where minutes % 60 == 0:
                title = "\(minutes / 60) 小时额度"
            default:
                title = index == 0 ? "短期限额" : "长期限额"
            }

            let remaining = max(0, min(100, Int((100 - window.usedPercent).rounded())))
            return UsagePeriod(
                id: index == 0 ? "primary" : "secondary",
                title: title,
                remainingPercent: remaining,
                resetText: Self.resetDescription(for: window.resetsAt, now: now)
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
            UsageMetric(id: "current", value: Self.formatTokens(firstThreadTokens), label: "最新线程"),
            UsageMetric(id: "week", value: Self.formatTokens(sevenDayTokens), label: "近 7 天"),
            UsageMetric(id: "total", value: Self.formatTokens(live.lifetimeTokens), label: "累计")
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
                time: Self.timeFormatter.string(from: thread.updatedAt),
                tokenText: Self.formatTokens(thread.totalTokens),
                progress: progress
            )
        }

        self.init(
            planLabel: Self.planLabel(for: live.rateLimits.planType),
            periods: periods,
            metrics: metrics,
            recentTasks: recentTasks,
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

    private static func resetDescription(for date: Date?, now: Date) -> String {
        guard let date else { return "重置时间未知" }
        let interval = max(0, date.timeIntervalSince(now))
        let relative: String
        if interval < 3_600 {
            relative = "\(max(1, Int(ceil(interval / 60)))) 分钟后"
        } else if interval < 86_400 {
            relative = "\(max(1, Int(interval / 3_600))) 小时后"
        } else {
            relative = "\(max(1, Int(interval / 86_400))) 天后"
        }
        return "重置 \(relative) (\(dateFormatter.string(from: date)))"
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
