import SwiftUI

struct AnalyticsChatsView: View {
    @ObservedObject var analytics: AnalyticsStore
    let language: AppLanguage
    let privacy: Bool
    @Binding var selection: String?

    var body: some View {
        let result = analytics.focusedResult
        VStack(spacing: 0) {
            HStack {
                Toggle(language.text("Group parent + children", "合并父聊天与子任务"), isOn: $analytics.filter.groupChildren)
                Spacer()
                Picker(language.text("Sort", "排序"), selection: $analytics.filter.sort) {
                    Text(language.text("Value", "价值")).tag(AnalyticsFilter.Sort.cost)
                    Text("Tokens").tag(AnalyticsFilter.Sort.tokens)
                    Text(language.text("Name", "名称")).tag(AnalyticsFilter.Sort.title)
                }.frame(width: 160)
                Button { analytics.filter.ascending.toggle() } label: {
                    Image(systemName: analytics.filter.ascending ? "arrow.up" : "arrow.down")
                }.help(language.text("Reverse sort", "反转排序"))
            }.padding(12)
            Table(result.chats, selection: $selection) {
                TableColumn(language.text("Chat", "聊天")) { chat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(privacy ? AnalyticsExport.privateChatName(chat.id) : chat.title).lineLimit(2)
                        if chat.sessionIDs.count > 1 {
                            Text(language.text("\(chat.sessionIDs.count) chats · exclusive usage summed", "\(chat.sessionIDs.count) 个聊天 · 独立增量合计"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.width(min: 170, ideal: 300)
                TableColumn("Tokens") { Text(AnalyticsFormat.compactTokens($0.totals.tokens)).monospacedDigit() }.width(90)
                TableColumn(language.text("Est. USD", "估算美元")) {
                    Text($0.totals.pricedTokens > 0 ? AnalyticsFormat.money($0.totals.usd) : "—").monospacedDigit()
                }.width(100)
                TableColumn(language.text("Priced", "已计价")) { Text(AnalyticsFormat.percent($0.totals.pricedShare)) }.width(70)
            }
            if result.chats.isEmpty {
                Text(language.text("No matching chats", "没有匹配的聊天")).foregroundStyle(.secondary).padding()
            }
            Text(language.text("Select a row for exact amounts and frozen rates. Displayed amounts are rounded; family totals count each chat once.",
                               "选择一行查看精确金额与冻结价格。展示金额经四舍五入，聊天组合计中每个聊天只计算一次。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let selected = result.chats.first(where: { $0.id == selection }) {
                AnalyticsRecordInspector(chat: selected, records: result.records.filter { selected.sessionIDs.contains($0.value.sessionID) },
                                         language: language, privacy: privacy) {
                    analytics.filter.familyID = analytics.data.rootID(for: selected.id)
                    analytics.filter.groupChildren = false
                    selection = nil
                }
                .inspectorColumnWidth(min: 250, ideal: 300, max: 380)
            }
        }
    }
}

private struct AnalyticsRecordInspector: View {
    let chat: AnalyticsChat
    let records: [AnalyticsRecord]
    let language: AppLanguage
    let privacy: Bool
    let drillDown: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(privacy ? AnalyticsExport.privateChatName(chat.id) : chat.title).font(.system(size: 17))
                Text(chat.totals.pricedTokens > 0 ? AnalyticsFormat.money(chat.totals.usd) : "—")
                    .font(.system(size: 25)).foregroundStyle(UsageDesign.blue)
                Button(language.text("Show each chat in this family", "逐个查看本组聊天"), action: drillDown)
                Text(language.text("Stored amounts and prices are retained. New unknown or inconsistent rows are left unpriced; historical priced rows are not silently rewritten.",
                                   "保留已入账金额与冻结价格。新发现的未知模型或分类异常记录不计价；已计价历史不会被静默改写。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(records) { row in
                    let r = row.value
                    VStack(alignment: .leading, spacing: 7) {
                        Text(r.usageDay + " · " + r.model).font(.system(size: 12))
                        LabeledContent(language.text("Input (includes cache)", "输入（含缓存）"), value: AnalyticsFormat.tokens(r.counts.inputTokens))
                        LabeledContent(language.text("Cached input", "缓存输入"), value: AnalyticsFormat.tokens(r.counts.cachedInputTokens))
                        LabeledContent(language.text("Output", "输出"), value: AnalyticsFormat.tokens(r.counts.outputTokens))
                        if let issue = r.accountingNote ?? r.counts.accountingIssue {
                            Text(issue).foregroundStyle(.orange)
                        }
                        if let price = r.price {
                            Text(language.text("USD per 1M: input / cache / output", "每百万 token 美元：输入 / 缓存 / 输出"))
                            Text("\(price.inputPerMillion) / \(price.cachedInputPerMillion) / \(price.outputPerMillion)")
                            Text(price.version).foregroundStyle(.secondary)
                            LabeledContent(language.text("Frozen amount", "入账金额"), value: String(format: "$%.6f", r.usd))
                            let delta = r.usd - SessionAPICostEstimator.estimatedUSD(price: price, counts: r.counts)
                            if abs(delta) > 0.000_001 {
                                Text(language.text("Difference from category calculation: ", "与分类复算差额：") + String(format: "$%.6f", delta)).foregroundStyle(.orange)
                            }
                        } else {
                            Text(language.text("Unpriced: ", "未计价：") + (r.accountingNote ?? "unknown-model")).foregroundStyle(.orange)
                        }
                        if let note = r.pricingBackfill {
                            Text(language.text("Backfilled: ", "补估时间：") + note.appliedAt).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 11)).monospacedDigit()
                    Divider()
                }
            }.padding(16)
        }
    }
}
