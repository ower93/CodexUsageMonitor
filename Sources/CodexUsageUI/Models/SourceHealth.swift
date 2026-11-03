import Foundation

enum UsageSource: String, CaseIterable, Codable, Sendable {
    case limits, account, threads, cost

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.limits, .english): "Account quota"
        case (.account, .english): "Account activity"
        case (.threads, .english): "Recent chats"
        case (.cost, .english): "Local estimate"
        case (.limits, _): "账户额度"
        case (.account, _): "账户活动"
        case (.threads, _): "最近对话"
        case (.cost, _): "本机估算"
        }
    }
}

struct SourceHealth: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case loading, live, stale, unavailable, demo }
    var state: State
    var lastSuccess: Date?
    var lastAttempt: Date?
    var message: String?

    static var loading: Self { Self(state: .loading) }
    static func success(at date: Date) -> Self {
        Self(state: .live, lastSuccess: date, lastAttempt: date)
    }
    func failing(_ message: String, at date: Date) -> Self {
        Self(state: lastSuccess == nil ? .unavailable : .stale,
             lastSuccess: lastSuccess, lastAttempt: date, message: message)
    }
    func title(_ language: AppLanguage) -> String {
        switch (state, language) {
        case (.loading, .english): "Loading"
        case (.live, .english): "Current"
        case (.stale, .english): "Stale"
        case (.unavailable, .english): "Unavailable"
        case (.demo, .english): "Demo"
        case (.loading, _): "读取中"
        case (.live, _): "已更新"
        case (.stale, _): "旧数据"
        case (.unavailable, _): "不可用"
        case (.demo, _): "演示"
        }
    }
}
