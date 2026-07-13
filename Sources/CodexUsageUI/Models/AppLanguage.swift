import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let storageKey = "app.language"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: "中文"
        case .english: "English"
        }
    }

    public static func systemMatch(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let preferredLanguage = preferredLanguages.first?.lowercased() else {
            return .english
        }
        return preferredLanguage.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    @MainActor
    public static func resolveAndPersist(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let rawValue = defaults.string(forKey: storageKey),
           let savedLanguage = AppLanguage(rawValue: rawValue) {
            return savedLanguage
        }

        let matchedLanguage = systemMatch(preferredLanguages: preferredLanguages)
        defaults.set(matchedLanguage.rawValue, forKey: storageKey)
        return matchedLanguage
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public var appTitle: String {
        switch self {
        case .simplifiedChinese: "Codex 用量"
        case .english: "Codex Usage"
        }
    }

    public func remainingAccessibilityLabel(percent: Int) -> String {
        switch self {
        case .simplifiedChinese: "Codex 剩余额度 \(percent)%"
        case .english: "Codex usage, \(percent)% remaining"
        }
    }

    public var refreshUsage: String {
        switch self {
        case .simplifiedChinese: "刷新用量"
        case .english: "Refresh Usage"
        }
    }

    public var quitApplication: String {
        switch self {
        case .simplifiedChinese: "退出 Codex 用量"
        case .english: "Quit Codex Usage"
        }
    }

    var demoStatus: String {
        switch self {
        case .simplifiedChinese: "演示数据 · 隐私保护"
        case .english: "Demo · Privacy Protected"
        }
    }

    var liveStatus: String {
        switch self {
        case .simplifiedChinese: "真实账户 · 实时刷新"
        case .english: "Live Account · Auto Refresh"
        }
    }

    var failureStatus: String {
        switch self {
        case .simplifiedChinese: "刷新失败 · 点击重试"
        case .english: "Refresh Failed · Click to Retry"
        }
    }

    func quotaTitle(durationMinutes: Int?, index: Int) -> String {
        switch (self, durationMinutes) {
        case (.simplifiedChinese, 300): "5 小时额度"
        case (.english, 300): "5-Hour Limit"
        case (.simplifiedChinese, 10_080): "7 天额度"
        case (.english, 10_080): "7-Day Limit"
        case (.simplifiedChinese, .some(let minutes)) where minutes % 1_440 == 0:
            "\(minutes / 1_440) 天额度"
        case (.english, .some(let minutes)) where minutes % 1_440 == 0:
            "\(minutes / 1_440)-Day Limit"
        case (.simplifiedChinese, .some(let minutes)) where minutes % 60 == 0:
            "\(minutes / 60) 小时额度"
        case (.english, .some(let minutes)) where minutes % 60 == 0:
            "\(minutes / 60)-Hour Limit"
        case (.simplifiedChinese, _): index == 0 ? "短期限额" : "长期限额"
        case (.english, _): index == 0 ? "Short-Term Limit" : "Long-Term Limit"
        }
    }

    func resetDescription(for date: Date?, now: Date) -> String {
        guard let date else {
            switch self {
            case .simplifiedChinese: return "重置时间未知"
            case .english: return "Reset time unavailable"
            }
        }

        let interval = max(0, date.timeIntervalSince(now))
        let relative: String
        if interval < 3_600 {
            let minutes = max(1, Int(ceil(interval / 60)))
            relative = self == .simplifiedChinese
                ? "\(minutes) 分钟后"
                : "in \(minutes) min"
        } else if interval < 86_400 {
            let hours = max(1, Int(interval / 3_600))
            relative = self == .simplifiedChinese
                ? "\(hours) 小时后"
                : "in \(hours) hr"
        } else {
            let days = max(1, Int(interval / 86_400))
            relative = self == .simplifiedChinese
                ? "\(days) 天后"
                : "in \(days) days"
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = self == .simplifiedChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        switch self {
        case .simplifiedChinese:
            return "重置 \(relative) (\(formatter.string(from: date)))"
        case .english:
            return "Resets \(relative) (\(formatter.string(from: date)))"
        }
    }

    var metricCurrent: String {
        switch self {
        case .simplifiedChinese: "最新线程"
        case .english: "Latest Thread"
        }
    }

    var metricSevenDays: String {
        switch self {
        case .simplifiedChinese: "近 7 天"
        case .english: "Last 7 Days"
        }
    }

    var metricLifetime: String {
        switch self {
        case .simplifiedChinese: "累计"
        case .english: "Lifetime"
        }
    }

    var previewCurrentMetric: String {
        switch self {
        case .simplifiedChinese: "本次任务"
        case .english: "Current Task"
        }
    }

    var remaining: String {
        switch self {
        case .simplifiedChinese: "剩余"
        case .english: "Remaining"
        }
    }

    var recentTasks: String {
        switch self {
        case .simplifiedChinese: "最近任务"
        case .english: "Recent Tasks"
        }
    }

    var threadTotalTokens: String {
        switch self {
        case .simplifiedChinese: "线程累计 token"
        case .english: "Thread total tokens"
        }
    }

    var apiCostTitle: String {
        switch self {
        case .simplifiedChinese: "已消耗 token 价值（估算）"
        case .english: "Token Cost (Est.)"
        }
    }

    var standardAPIRates: String {
        switch self {
        case .simplifiedChinese: "API 标准价"
        case .english: "Standard API rates"
        }
    }

    var lifetimeCost: String {
        switch self {
        case .simplifiedChinese: "生涯总费用"
        case .english: "Lifetime Cost"
        }
    }

    var noPricedModel: String {
        switch self {
        case .simplifiedChinese: "暂无公开 API 定价模型"
        case .english: "No public API-priced model"
        }
    }

    func pricedCoverage(_ percent: Int) -> String {
        switch self {
        case .simplifiedChinese: "可计价 \(percent)%"
        case .english: "Priced \(percent)%"
        }
    }

    var costDisclaimer: String {
        switch self {
        case .simplifiedChinese: "按输入 / 缓存输入 / 输出 token 分别估算，不含税费与长上下文加价"
        case .english: "Token types priced separately; excludes tax and surcharges."
        }
    }

    var refreshFromAccountHint: String {
        switch self {
        case .simplifiedChinese: "从 Codex 账户刷新真实用量"
        case .english: "Refresh live usage from your Codex account"
        }
    }

    var showSettings: String {
        switch self {
        case .simplifiedChinese: "显示设置"
        case .english: "Show Settings"
        }
    }

    func availableResets(_ count: Int) -> String {
        switch self {
        case .simplifiedChinese: "可用重置 \(count) 次"
        case .english: "\(count) resets available"
        }
    }

    func updatedAt(_ time: String) -> String {
        switch self {
        case .simplifiedChinese: "更新于 \(time)"
        case .english: "Updated \(time)"
        }
    }

    var settingsTitle: String {
        switch self {
        case .simplifiedChinese: "显示设置"
        case .english: "Display Settings"
        }
    }

    var showAll: String {
        switch self {
        case .simplifiedChinese: "全部显示"
        case .english: "Show All"
        }
    }

    var closeSettings: String {
        switch self {
        case .simplifiedChinese: "关闭设置"
        case .english: "Close Settings"
        }
    }

    var cardsSection: String {
        switch self {
        case .simplifiedChinese: "显示卡片"
        case .english: "Cards"
        }
    }

    var usageSummaryCard: String {
        switch self {
        case .simplifiedChinese: "额度与 Token 概览"
        case .english: "Usage & Token Summary"
        }
    }

    var costCard: String {
        switch self {
        case .simplifiedChinese: "Token 价值估算"
        case .english: "Token Cost Estimate"
        }
    }

    var generalSection: String {
        switch self {
        case .simplifiedChinese: "通用"
        case .english: "General"
        }
    }

    var languageSetting: String {
        switch self {
        case .simplifiedChinese: "语言"
        case .english: "Language"
        }
    }

    var launchAtLogin: String {
        switch self {
        case .simplifiedChinese: "开机时启动"
        case .english: "Launch at Login"
        }
    }

    var approvalRequired: String {
        switch self {
        case .simplifiedChinese: "需要在系统设置中允许"
        case .english: "Allow in System Settings"
        }
    }

    var openSettings: String {
        switch self {
        case .simplifiedChinese: "前往设置"
        case .english: "Open Settings"
        }
    }

    func settingsFailure(_ description: String) -> String {
        switch self {
        case .simplifiedChinese: "设置失败：\(description)"
        case .english: "Update failed: \(description)"
        }
    }

    var enabledAccessibilityValue: String {
        switch self {
        case .simplifiedChinese: "已开启"
        case .english: "On"
        }
    }

    var disabledAccessibilityValue: String {
        switch self {
        case .simplifiedChinese: "已关闭"
        case .english: "Off"
        }
    }

    var previewTasks: [(title: String, time: String, token: String)] {
        switch self {
        case .simplifiedChinese:
            [
                ("任务信息已隐藏", "隐私保护", "已隐藏"),
                ("本地线程已隐藏", "隐私保护", "已隐藏"),
                ("仅展示界面效果", "演示数据", "已隐藏")
            ]
        case .english:
            [
                ("Task details hidden", "Privacy protected", "Hidden"),
                ("Local thread hidden", "Privacy protected", "Hidden"),
                ("Interface preview only", "Demo data", "Hidden")
            ]
        }
    }
}
