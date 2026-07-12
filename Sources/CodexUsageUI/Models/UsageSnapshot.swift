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

struct UsageSnapshot: Codable, Sendable {
    var planLabel: String
    var periods: [UsagePeriod]
    var metrics: [UsageMetric]
    var recentTasks: [RecentTask]
    var availableResets: Int
    var updatedAt: Date

    static let preview = UsageSnapshot(
        planLabel: "PRO",
        periods: [
            UsagePeriod(
                id: "five-hour",
                title: "5 小时额度",
                remainingPercent: 78,
                resetText: "重置 3 小时后 (7月12日 18:41)"
            ),
            UsagePeriod(
                id: "seven-day",
                title: "7 天额度",
                remainingPercent: 72,
                resetText: "重置 5 天后 (7月18日 14:45)"
            )
        ],
        metrics: [
            UsageMetric(id: "current", value: "24.80M", label: "本次任务"),
            UsageMetric(id: "week", value: "1.26B", label: "近 7 天"),
            UsageMetric(id: "total", value: "3.84B", label: "累计")
        ],
        recentTasks: [
            RecentTask(
                id: "hidden-1",
                title: "任务信息已隐藏",
                time: "隐私保护",
                tokenText: "已隐藏",
                progress: 0.88
            ),
            RecentTask(
                id: "hidden-2",
                title: "本地线程已隐藏",
                time: "隐私保护",
                tokenText: "已隐藏",
                progress: 0.62
            ),
            RecentTask(
                id: "hidden-3",
                title: "仅展示界面效果",
                time: "演示数据",
                tokenText: "已隐藏",
                progress: 0.35
            )
        ],
        availableResets: 2,
        updatedAt: Date()
    )
}
