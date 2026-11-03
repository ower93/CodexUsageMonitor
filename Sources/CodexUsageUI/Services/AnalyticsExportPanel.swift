import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AnalyticsExportPanel {
    enum Failure: Error { case renderingFailed }

    static func saveCSV(_ result: AnalyticsResult, data: AnalyticsData, privacy: Bool) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "codex-usage-\(AnalyticsFilter.day(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try Data(AnalyticsExport.csv(result, data: data, privacy: privacy).utf8).write(to: url, options: .atomic)
    }

    static func saveImage(_ result: AnalyticsResult, language: AppLanguage) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "codex-usage-private-\(AnalyticsFilter.day(Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try renderImage(result, language: language).write(to: url, options: .atomic)
    }

    static func renderImage(_ result: AnalyticsResult, language: AppLanguage) throws -> Data {
        let renderer = ImageRenderer(content: AnalyticsShareCard(result: result, language: language))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:])
        else { throw Failure.renderingFailed }
        return data
    }
}

private struct AnalyticsShareCard: View {
    let result: AnalyticsResult
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("Codex Usage 2.0", systemImage: "gauge.with.dots.needle.67percent")
                Spacer()
                Text(language.text("Privacy protected", "隐私保护"))
            }.font(UsageDesign.font(18, language: language))
            Text(language.text("API-equivalent estimate", "API 等值估算"))
                .font(UsageDesign.font(30, language: language))
            Text((result.range.start ?? language.text("Local history", "本机历史")) + " — " + (result.range.end ?? "—"))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                Text(result.totals.pricedTokens > 0 ? AnalyticsFormat.money(result.totals.usd) : "—")
                    .font(.system(size: 46, weight: .regular, design: .rounded)).foregroundStyle(UsageDesign.blue)
                Text("\(AnalyticsFormat.compactTokens(result.totals.tokens)) tokens")
                    .font(.system(size: 22))
            }
            Text(language.text("Priced token share: ", "token 计价覆盖：") + AnalyticsFormat.percent(result.totals.pricedShare))
            Divider()
            ForEach(result.chats.prefix(10)) { chat in
                HStack {
                    Text(AnalyticsExport.privateChatName(chat.id))
                    Spacer()
                    Text("\(AnalyticsFormat.compactTokens(chat.totals.tokens)) tokens").foregroundStyle(.secondary)
                    Text(chat.totals.pricedTokens > 0 ? AnalyticsFormat.money(chat.totals.usd) : "—").frame(width: 135, alignment: .trailing)
                }.monospacedDigit()
            }
            Divider()
            Text(language.text("Local records only · Frozen standard API rates · Not a bill or proven saving\nUnpriced records are excluded from USD; existing frozen estimates are retained. Top 10 matching chat groups shown.",
                               "仅本机记录 · 冻结的标准 API 价格 · 非账单或已证实的节省\n未计价记录不计入美元汇总，已有冻结估算保留。展示筛选后前 10 个聊天组。"))
                .font(UsageDesign.font(12, language: language)).foregroundStyle(.secondary)
        }
        .padding(36).frame(width: 900).background(Color.white)
        .environment(\.colorScheme, .light)
        .font(UsageDesign.font(16, language: language))
    }
}
