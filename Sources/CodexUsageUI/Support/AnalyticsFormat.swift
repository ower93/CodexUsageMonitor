import Foundation

enum AnalyticsFormat {
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))) }
    static func tokens(_ value: Int64) -> String { value.formatted(.number.grouping(.automatic)) }
    static func compactTokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1e9) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1e6) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1e3) }
        return String(value)
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
}

extension AppLanguage {
    func text(_ english: String, _ chinese: String) -> String { self == .english ? english : chinese }
}
