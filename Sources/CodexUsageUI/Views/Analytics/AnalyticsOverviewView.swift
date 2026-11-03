import Charts
import SwiftUI

struct AnalyticsOverviewView: View {
    @ObservedObject var analytics: AnalyticsStore
    let language: AppLanguage
    let privacy: Bool
    let openChats: () -> Void

    var body: some View {
        let result = analytics.result
        let focused = analytics.focusedResult
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(language.text("API-equivalent value, not a bill", "API 等值估算，并非实际账单"))
                    .font(UsageDesign.font(22, language: language))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading, spacing: 16) {
                    metric(language.text("Estimated value", "估算价值"), value: focused.totals.pricedTokens > 0 ? AnalyticsFormat.money(focused.totals.usd) : "—")
                    metric(language.text("Recorded tokens", "已记录 token"), value: AnalyticsFormat.compactTokens(focused.totals.tokens))
                    metric(language.text("Priced token share", "token 计价覆盖"), value: AnalyticsFormat.percent(focused.totals.pricedShare))
                    metric(language.text("Cache share · valid rows", "缓存占比 · 有效记录"), value: AnalyticsFormat.percent(focused.totals.cacheShare))
                }
                if let comparison = result.comparison {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(language.text("Like-for-like: \(comparison.completedDays) completed days", "可比区间：\(comparison.completedDays) 个完整日"))
                        Text("\(comparison.current.pricedTokens > 0 ? AnalyticsFormat.money(comparison.current.usd) : "—") / \(comparison.previous.pricedTokens > 0 ? AnalyticsFormat.money(comparison.previous.usd) : "—") · "
                             + language.text("current / prior week", "本周 / 上周"))
                            .foregroundStyle(.secondary)
                        Text(language.text("Today is excluded from both comparison windows. Coverage may differ.", "比较不含今天，两期的数据覆盖可能不同。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if result.records.isEmpty {
                    ContentUnavailableView(language.text("No local records in this range", "此区间暂无本机记录"),
                                           systemImage: "chart.bar.xaxis",
                                           description: Text(language.text("Try another date range or check Data Health.", "请尝试其他日期区间，或检查数据状态。")))
                } else {
                    dailyChart(result.days, cost: true)
                    dailyChart(result.days, cost: false)
                    HStack {
                        Text(language.text("Exact daily values", "每日精确值"))
                        Spacer()
                        Button(language.text("Explore chats", "查看聊天明细"), action: openChats)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            Text(language.text("Recorded day", "记录日期"))
                            Text("Tokens")
                            Text(language.text("Estimated USD", "估算美元"))
                        }.foregroundStyle(.secondary)
                        ForEach(result.days.suffix(90)) { day in
                            GridRow {
                                Button(day.id) { analytics.selectedDay = day.id; openChats() }.buttonStyle(.link)
                                Text(AnalyticsFormat.tokens(day.totals.tokens)).monospacedDigit()
                                Text(day.totals.pricedTokens > 0 ? AnalyticsFormat.money(day.totals.usd) : "—").monospacedDigit()
                            }
                        }
                    }
                }
                Text(language.text("Charts show up to 90 recorded days; totals use the full filter. Missing days mean no local record, not confirmed zero account activity.",
                                   "图表最多展示 90 个有记录的日期，汇总使用完整筛选范围。缺少日期代表无本机记录，不代表账户实际用量为零。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .regular, design: .rounded)).monospacedDigit().foregroundStyle(UsageDesign.blue)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dailyChart(_ days: [AnalyticsDay], cost: Bool) -> some View {
        let visibleDays = Array(days.suffix(90))
        let step = max(1, Int(ceil(Double(visibleDays.count) / 6)))
        let tickDays = visibleDays.enumerated().compactMap { index, day in index % step == 0 ? day.id : nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text(cost ? language.text("Daily estimated value · USD", "每日估算价值 · 美元") : language.text("Daily recorded tokens", "每日已记录 token"))
            Chart(visibleDays) { day in
              if !cost || day.totals.pricedTokens > 0 {
                BarMark(x: .value("Day", day.id), y: .value(cost ? "USD" : "Tokens", cost ? day.totals.usd : Double(day.totals.tokens)))
                    .foregroundStyle(UsageDesign.blue.opacity(analytics.selectedDay == nil || analytics.selectedDay == day.id ? 0.9 : 0.35))
                    .accessibilityLabel(day.id)
                    .accessibilityValue(cost ? AnalyticsFormat.money(day.totals.usd) : AnalyticsFormat.tokens(day.totals.tokens))
              }
            }
            .chartXScale(domain: visibleDays.map(\.id))
            .chartXSelection(value: $analytics.selectedDay)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { value in
                    proxy.selectXValue(at: value.location.x)
                }
            }
            .chartXAxis {
                AxisMarks(values: tickDays) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let day = value.as(String.self) { Text(String(day.suffix(5))) }
                    }
                }
            }
            .frame(height: 170)
            if let selected = analytics.selectedDay, let day = days.first(where: { $0.id == selected }) {
                Text("\(selected) · \(AnalyticsFormat.tokens(day.totals.tokens)) tokens · \(day.totals.pricedTokens > 0 ? AnalyticsFormat.money(day.totals.usd) : "—")")
                    .font(.system(size: 12)).monospacedDigit()
            }
        }
    }
}
