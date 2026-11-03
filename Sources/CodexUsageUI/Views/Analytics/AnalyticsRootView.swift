import SwiftUI

public struct AnalyticsRootView: View {
    @ObservedObject private var usage: UsageStore
    @StateObject private var analytics: AnalyticsStore
    @AppStorage("display.privacyMode") private var privacy = true
    @State private var section: AnalyticsSection? = .overview
    @State private var selectedChat: String?
    @State private var exportError: String?
    private let refresh: () -> Void
    private var language: AppLanguage { usage.language }

    public init(store: UsageStore, refresh: @escaping () -> Void) {
        usage = store
        _analytics = StateObject(wrappedValue: AnalyticsStore(previewData: store.isDemo ? .demo() : nil))
        self.refresh = refresh
    }

    public var body: some View {
        NavigationSplitView {
            List(AnalyticsSection.allCases, selection: $section) { destination in
                Label(destination.title(language), systemImage: destination.symbol).tag(destination)
                    .accessibilityIdentifier("analytics.section.\(destination.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 145, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex Usage 2.0").font(.system(size: 12))
                    Text(language.text("Local data · API-equivalent estimates", "本机数据 · API 等值估算"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if usage.isDemo {
                    Text(language.text("DEMO · Synthetic data only", "演示模式 · 仅使用虚构数据"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(6)
                }
                if section != .health { filterBar }
                if let exportError {
                    Text(exportError).foregroundStyle(.red).padding(8)
                }
                if analytics.error != nil {
                    Label(language.text("Analytics could not refresh. Last loaded data is retained.", "分析数据刷新失败，保留上次读取的内容。"),
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding(10)
                }
                switch section ?? .overview {
                case .overview:
                    AnalyticsOverviewView(analytics: analytics, language: language, privacy: privacy,
                                          openChats: { section = .chats })
                case .chats:
                    AnalyticsChatsView(analytics: analytics, language: language, privacy: privacy, selection: $selectedChat)
                case .models:
                    AnalyticsModelsView(result: analytics.focusedResult, language: language) { model in
                        analytics.filter.model = model
                        section = .chats
                    }
                case .health:
                    AnalyticsHealthView(usage: usage, analytics: analytics, privacy: privacy)
                }
            }
            .navigationTitle((section ?? .overview).title(language))
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $privacy) { Image(systemName: privacy ? "eye.slash" : "eye") }
                        .help(language.text("Privacy mode: hide chat names", "隐私模式：隐藏聊天名称"))
                        .accessibilityLabel(language.text("Privacy mode", "隐私模式"))
                        .accessibilityIdentifier("analytics.privacy")
                        .toggleStyle(.button)
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help(language.refreshUsage).keyboardShortcut("r")
                        .accessibilityLabel(language.refreshUsage)
                        .accessibilityIdentifier("analytics.refresh")
                    Menu {
                        Button(language.text("Export filtered CSV…", "导出筛选后的 CSV…")) {
                            do { try AnalyticsExportPanel.saveCSV(analytics.focusedResult, data: analytics.data, privacy: privacy) }
                            catch { exportError = language.text("Export failed", "导出失败") }
                        }
                        Button(language.text("Export privacy-safe image…", "导出隐私保护图片…")) {
                            do { try AnalyticsExportPanel.saveImage(analytics.focusedResult, language: language) }
                            catch { exportError = language.text("Image export failed", "图片导出失败") }
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .help(language.text("Export", "导出"))
                    .accessibilityLabel(language.text("Export", "导出"))
                }
            }
        }
        .font(UsageDesign.font(13, language: language))
        .fontWeight(.regular)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await analytics.reload() }
        .onChange(of: usage.costHealth.completedAt) { _, _ in Task { await analytics.reload() } }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Picker(language.text("Period", "期间"), selection: $analytics.filter.period) {
                    ForEach(AnalyticsFilter.Period.allCases, id: \.self) { Text($0.title(language)).tag($0) }
                }.frame(maxWidth: 230)
                Picker(language.text("Model", "模型"), selection: $analytics.filter.model) {
                    Text(language.text("All models", "全部模型")).tag("")
                    ForEach(Array(Set(analytics.data.records.map { $0.value.model })).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 300)
                Spacer(minLength: 0)
                if analytics.isLoading { ProgressView().controlSize(.small) }
            }
            if analytics.filter.period == .custom {
                HStack {
                    TextField("YYYY-MM-DD", text: $analytics.filter.customStart).frame(width: 120)
                    Text("–")
                    TextField("YYYY-MM-DD", text: $analytics.filter.customEnd).frame(width: 120)
                    if !analytics.result.range.isValid { Text(language.text("Invalid date range", "日期范围无效")).foregroundStyle(.red) }
                }
            }
            HStack {
                TextField(language.text("Search chat names or IDs", "搜索聊天名称或编号"), text: $analytics.filter.search)
                    .textFieldStyle(.roundedBorder)
                if let day = analytics.selectedDay {
                    Button("\(day) ×") { analytics.selectedDay = nil }
                        .help(language.text("Clear selected day", "清除选中日期"))
                }
                if analytics.filter.familyID != nil {
                    Button(language.text("All families", "全部聊天组")) { analytics.filter.familyID = nil }
                }
            }
            Text(language.text("Local recorded days · Monday 00:00 week · ", "本机记录日期 · 周一 00:00 起算 · ") + TimeZone.current.identifier)
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14)
        .background(.bar)
    }
}

private enum AnalyticsSection: String, CaseIterable, Identifiable {
    case overview, chats, models, health
    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .overview: language.text("Overview", "概览")
        case .chats: language.text("Chats", "聊天明细")
        case .models: language.text("Models", "模型")
        case .health: language.text("Data Health", "数据状态")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .chats: "bubble.left.and.bubble.right"
        case .models: "cpu"
        case .health: "checkmark.shield"
        }
    }
}
