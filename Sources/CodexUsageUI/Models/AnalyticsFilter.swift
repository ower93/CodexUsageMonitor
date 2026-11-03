import Foundation

struct AnalyticsFilter: Codable, Equatable, Sendable {
    enum Period: String, Codable, CaseIterable, Sendable {
        case thisWeek, lastWeek, last30Days, allTime, custom
        func title(_ language: AppLanguage) -> String {
            switch (self, language) {
            case (.thisWeek, .english): "This week"
            case (.thisWeek, _): "本周"
            case (.lastWeek, .english): "Last week"
            case (.lastWeek, _): "上周"
            case (.last30Days, .english): "Last 30 days"
            case (.last30Days, _): "近 30 天"
            case (.allTime, .english): "Local lifetime"
            case (.allTime, _): "本机生涯"
            case (.custom, .english): "Custom dates"
            case (.custom, _): "自定日期"
            }
        }
    }
    enum Sort: String, Codable, CaseIterable, Sendable { case cost, tokens, title }
    var period: Period = .thisWeek
    var customStart = ""
    var customEnd = ""
    var model: String = ""
    var search = ""
    var groupChildren = true
    var sort: Sort = .cost
    var ascending = false
    var familyID: String? = nil

    func range(now: Date = Date(), calendar: Calendar = .current) -> AnalyticsDayRange {
        let today = calendar.startOfDay(for: now)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -mondayOffset, to: today) ?? today
        switch period {
        case .thisWeek: return AnalyticsDayRange(start: Self.day(monday, calendar), end: Self.day(today, calendar))
        case .lastWeek:
            return AnalyticsDayRange(start: Self.day(calendar.date(byAdding: .day, value: -7, to: monday) ?? monday, calendar),
                                     end: Self.day(calendar.date(byAdding: .day, value: -1, to: monday) ?? monday, calendar))
        case .last30Days:
            return AnalyticsDayRange(start: Self.day(calendar.date(byAdding: .day, value: -29, to: today) ?? today, calendar),
                                     end: Self.day(today, calendar))
        case .allTime: return AnalyticsDayRange(start: nil, end: Self.day(today, calendar))
        case .custom:
            guard let start = Self.date(customStart, calendar), let end = Self.date(customEnd, calendar), start <= min(end, today) else {
                return AnalyticsDayRange(start: nil, end: nil, isValid: false)
            }
            return AnalyticsDayRange(start: Self.day(start, calendar), end: Self.day(min(end, today), calendar))
        }
    }

    static func day(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ day: String, _ calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, day.count == 10,
              let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.day(value, calendar) == day else { return nil }
        return value
    }
}

struct AnalyticsDayRange: Equatable, Sendable {
    let start: String?
    let end: String?
    var isValid = true
    func contains(_ day: String) -> Bool {
        isValid && (start == nil || day >= start!) && (end == nil || day <= end!)
    }
}
