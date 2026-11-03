import Foundation

struct CostIngestionHealth: Codable, Sendable {
    struct Issue: Codable, Hashable, Sendable {
        let sessionID: String?
        let code: String
    }
    var discoveredFiles = 0
    var indexedFiles = 0
    var unchangedFiles = 0
    var filesWithUsage = 0
    var issues: [Issue] = []
    var completedAt: Date?

    mutating func record(_ code: String, sessionID: String? = nil) {
        let issue = Issue(sessionID: sessionID, code: code)
        if !issues.contains(issue) { issues.append(issue) }
    }

    static func description(_ code: String, language: AppLanguage) -> String {
        let descriptions: [String: (String, String)] = [
            "session-roots-unavailable": ("Session folders unavailable", "会话文件夹不可用"),
            "file-unreadable": ("File could not be read", "文件不可读"),
            "metadata-unresolved": ("Session metadata unresolved", "会话元数据未确认"),
            "child-counter-baseline-unresolved": ("Child counter baseline unknown", "子任务计数基线未知"),
            "log-read-failed": ("Log parsing failed", "日志解析失败"),
            "counters-below-checkpoint": ("Counters below saved checkpoint", "计数低于已存检查点"),
            "increment-reconciliation-failed": ("Token increments do not reconcile", "token 增量无法对账"),
            "inconsistent-cache-delta": ("Cache increment exceeds input", "缓存增量超过输入增量"),
            "inconsistent-total-delta": ("Total differs from input + output", "总增量与输入加输出不符"),
            "malformed-token-event": ("Malformed token event", "token 事件格式异常"),
            "non-monotonic-counter": ("Counter decreased unexpectedly", "累计计数出现回退"),
            "analytics-database-unavailable": ("Analytics database unavailable", "分析数据库不可用"),
            "ledger-read-or-write-failed": ("Ledger could not be read or saved", "账本读取或保存失败"),
            "cancelled": ("Scan cancelled", "采集已取消")
        ]
        if code.hasPrefix("unpriced-model:") {
            return language.text("Unknown price: ", "未知价格：") + code.dropFirst("unpriced-model:".count)
        }
        guard let value = descriptions[code] else { return code }
        return language.text(value.0, value.1)
    }
}

struct CostScanResult: Sendable {
    let estimate: CodexAPICostEstimate?
    let health: CostIngestionHealth
    var failure: String? = nil
}
