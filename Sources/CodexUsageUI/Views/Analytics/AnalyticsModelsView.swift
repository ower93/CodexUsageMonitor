import SwiftUI

struct AnalyticsModelsView: View {
    let result: AnalyticsResult
    let language: AppLanguage
    let select: (String) -> Void
    @State private var selectedModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("Compare observed usage, not model quality", "比较已观测用量，不代表模型质量"))
                .font(.system(size: 20)).padding(.horizontal, 16).padding(.top, 16)
            Table(result.models, selection: $selectedModel) {
                TableColumn(language.text("Model", "模型")) { row in
                    Text(row.id).foregroundStyle(UsageDesign.blue)
                }.width(min: 150, ideal: 230)
                TableColumn("Tokens") { Text(AnalyticsFormat.compactTokens($0.totals.tokens)) }.width(90)
                TableColumn(language.text("Est. USD", "估算美元")) {
                    Text($0.totals.pricedTokens > 0 ? AnalyticsFormat.money($0.totals.usd) : "—")
                }.width(100)
                TableColumn(language.text("Cache share", "缓存占比")) { Text(AnalyticsFormat.percent($0.totals.cacheShare)) }.width(90)
                TableColumn(language.text("Priced", "计价覆盖")) { Text(AnalyticsFormat.percent($0.totals.pricedShare)) }.width(80)
            }
            .onChange(of: selectedModel) { _, model in if let model { select(model) } }
            Text(language.text("Cache share uses valid category rows. Select a model to inspect its chats. Frozen historical prices may differ from today's catalog.",
                               "缓存占比使用分类有效的记录。点击模型查看相关聊天。历史冻结价格可能与当前价格表不同。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
        }
    }
}
