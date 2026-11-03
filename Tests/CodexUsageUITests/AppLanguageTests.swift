import Foundation
import Testing
@testable import CodexUsageUI

struct AppLanguageTests {
    @Test(arguments: ["zh-Hans-CN", "zh-Hant-TW", "zh"])
    func matchesChineseSystemLanguages(_ identifier: String) {
        #expect(AppLanguage.systemMatch(preferredLanguages: [identifier]) == .simplifiedChinese)
    }

    @Test(arguments: ["en-US", "fr-FR", "ja-JP"])
    func fallsBackToEnglishForOtherSystemLanguages(_ identifier: String) {
        #expect(AppLanguage.systemMatch(preferredLanguages: [identifier]) == .english)
    }

    @Test @MainActor
    func persistsFirstLaunchMatchAndKeepsUserSelection() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = AppLanguage.resolveAndPersist(
            defaults: defaults,
            preferredLanguages: ["zh-Hans-CN"]
        )
        #expect(firstLaunch == .simplifiedChinese)

        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        let laterLaunch = AppLanguage.resolveAndPersist(
            defaults: defaults,
            preferredLanguages: ["zh-Hans-CN"]
        )
        #expect(laterLaunch == .english)
    }

    @Test
    func createsAnEnglishPreviewSnapshot() {
        let snapshot = UsageSnapshot.preview(language: .english)

        #expect(snapshot.periods.first?.title == "5-Hour Limit")
        #expect(snapshot.metrics.map(\.label) == ["Latest Chat", "Last 7 Days", "Account Total"])
        #expect(snapshot.recentTasks.first?.tokenText == "Hidden")
    }

    @Test
    func previewCostMatchesAnalyticsDemoForTheSameDate() throws {
        let now = Date(timeIntervalSince1970: 1_791_230_400)
        let data = AnalyticsData.demo(now: now)
        let week = AnalyticsEngine.summarize(data, filter: AnalyticsFilter(), now: now)
        var lifetime = AnalyticsFilter()
        lifetime.period = .allTime
        let all = AnalyticsEngine.summarize(data, filter: lifetime, now: now)
        for language in [AppLanguage.english, .simplifiedChinese] {
            let cost = try #require(UsageSnapshot.preview(language: language, now: now).apiCostEstimate)
            #expect(cost.currentWeekUSD == week.totals.usd)
            #expect(cost.lifetimeUSD == all.totals.usd)
        }
    }

    @Test
    func localizesCostWeekWithoutChangingAccountSevenDayLabels() {
        #expect(AppLanguage.simplifiedChinese.metricCurrentWeek == "本周")
        #expect(AppLanguage.english.metricCurrentWeek == "This Week")
        #expect(AppLanguage.simplifiedChinese.currentWeekStart == "周一 00:00 起")
        #expect(AppLanguage.english.currentWeekStart == "Since Mon 00:00")
        #expect(AppLanguage.simplifiedChinese.metricSevenDays == "近 7 天")
        #expect(AppLanguage.english.metricSevenDays == "Last 7 Days")
    }
}
