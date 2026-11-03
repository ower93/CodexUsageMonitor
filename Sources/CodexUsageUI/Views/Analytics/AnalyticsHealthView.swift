import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AnalyticsHealthView: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var analytics: AnalyticsStore
    let privacy: Bool
    var scrolls = true
    @AppStorage(CodexEnvironment.executableOverrideKey) private var executableOverride = ""
    @State private var catalogMessage: String?
    @State private var catalogRevision = PricingCatalogStore.shared.catalog?.revision
    private var language: AppLanguage { usage.language }

    var body: some View {
        if scrolls {
            ScrollView { content }
                .accessibilityIdentifier("health.content")
        } else {
            content
        }
    }

    // Kept independently hostable for component accessibility tests. The
    // production window still uses the native scroll container above.
    private var content: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text(language.text("Know what the numbers cover", "了解数字的覆盖范围"))
                    .font(UsageDesign.font(22, language: language))
                    .accessibilityAddTraits(.isHeader)
                GroupBox(language.text("Source freshness", "来源与新鲜度")) {
                    VStack(spacing: 12) {
                        ForEach(UsageSource.allCases, id: \.self) { source in
                            let health = usage.sourceHealth[source] ?? .loading
                            HStack(alignment: .top) {
                                Image(systemName: health.state == .live ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(health.state == .live ? Color.green : Color.orange)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title(language) + " · " + health.title(language))
                                    Text(health.lastSuccess.map { $0.formatted(date: .abbreviated, time: .standard) }
                                         ?? language.text("No successful read yet", "尚无成功读取记录"))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    if !privacy, let message = health.message {
                                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityLabel(source.title(language))
                            .accessibilityValue(sourceValue(health))
                            .accessibilityIdentifier("health.source.\(source.rawValue)")
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(language.text("Local ingestion — separate from pricing coverage", "本机采集情况 — 与计价覆盖率不同")) {
                    VStack(alignment: .leading, spacing: 9) {
                        metric(language.text("Files discovered / indexed", "发现 / 已索引文件"), value: "\(usage.costHealth.discoveredFiles) / \(usage.costHealth.indexedFiles)", id: "files")
                        metric(language.text("Unchanged files skipped", "跳过未变化文件"), value: "\(usage.costHealth.unchangedFiles)", id: "unchanged")
                        metric(language.text("Files with usage counters", "含用量计数的文件"), value: "\(usage.costHealth.filesWithUsage)", id: "usageFiles")
                        metric(language.text("Data issues", "数据问题"), value: "\(usage.costHealth.issues.count)", id: "issues")
                        ForEach(Array(Dictionary(grouping: usage.costHealth.issues, by: \.code).keys).sorted(), id: \.self) { code in
                            HStack {
                                Text(CostIngestionHealth.description(code, language: language)).help(code).textSelection(.enabled)
                                Spacer()
                                Text("\(usage.costHealth.issues.filter { $0.code == code }.count)")
                            }.font(.system(size: 11)).foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                        }
                        Text(language.text("A high priced-token share does not mean every log was ingested. Missing, inconsistent and unpriced data are shown separately.",
                                           "计价覆盖率高，不代表所有日志都被采集。缺失、分类异常和未计价记录分别显示。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(language.text("Connection & pricing diagnostics", "连接与价格诊断")) {
                    VStack(alignment: .leading, spacing: 9) {
                        metric("CODEX_HOME", value: privacy ? language.text("Hidden", "已隐藏") : CodexEnvironment.home().path, id: "home")
                        metric(language.text("Catalog verified", "价格核实日期"), value: PricingCatalogStore.shared.catalog?.verifiedAt ?? "—", id: "catalogDate")
                        metric(language.text("Pricing catalog revision", "价格表版本"), value: catalogRevision.map(String.init) ?? "—", id: "catalogRevision")
                        Text(PricingCatalogStore.shared.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(language.text("Import signed price catalog…", "导入签名价格表…")) { importCatalog() }
                            .disabled(!PricingCatalogStore.shared.updatesConfigured || usage.isDemo)
                            .accessibilityIdentifier("health.importCatalog")
                        if !PricingCatalogStore.shared.updatesConfigured {
                            Text(language.text("Catalog updates are disabled: this build has no pinned signing key. Bundled prices work offline.",
                                               "此构建未配置签名公钥，价格表更新已停用。内置价格可离线使用。"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let catalogMessage { Text(catalogMessage).font(.system(size: 11)).textSelection(.enabled) }
                        metric(language.text("Analytics imported", "分析数据导入时间"), value: analytics.data.importedAt?.formatted(date: .abbreviated, time: .standard) ?? "—", id: "importedAt")
                        if !privacy {
                            Text(language.text("Codex executable override · restart required", "自定义 Codex 可执行文件 · 重启生效"))
                            AccessibleExecutablePathField(text: $executableOverride, language: language)
                                .frame(maxWidth: .infinity, minHeight: 22)
                            Text(resolvedExecutable).font(.system(size: 11)).textSelection(.enabled)
                        } else {
                            Text(language.text("Turn off privacy mode to inspect or edit local paths.", "关闭隐私模式后可查看或编辑本机路径。"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(language.text("Account quota and account token activity are reported by Codex. USD estimates use only locally available records and frozen standard API prices; they are neither subscription charges nor proven savings. Deleted or unavailable history may be missing. No prompts or credentials are exported.",
                                   "账户额度与账户 token 活动由 Codex 报告。美元估算只覆盖本机可用记录，使用冻结的标准 API 价格；不是订阅账单或已证实的节省金额。已删除或不可用的历史可能缺失。导出不包含提示词和凭据。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(22)
    }

    private func metric(_ title: String, value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier("health.\(id)")
    }

    private func sourceValue(_ health: SourceHealth) -> String {
        var parts = [health.title(language), health.lastSuccess.map { $0.formatted(date: .abbreviated, time: .standard) }
                     ?? language.text("No successful read yet", "尚无成功读取记录")]
        if !privacy, let message = health.message { parts.append(message) }
        return parts.joined(separator: ", ")
    }

    private var resolvedExecutable: String {
        let override = CodexEnvironment.executableOverride()
        return (try? CodexAppServerClient.resolveCodexExecutable(candidates: override.map { [$0] }).path)
            ?? language.text("No executable found", "未找到可执行文件")
    }

    private func importCatalog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 512 * 1024 else { throw PricingCatalogStore.Failure.tooLarge }
            try PricingCatalogStore.shared.install(Data(contentsOf: url))
            catalogRevision = PricingCatalogStore.shared.catalog?.revision
            catalogMessage = language.text("Verified. New usage uses the new catalog; recorded prices and amounts are unchanged.",
                                           "已验证。新用量使用新价格；已记录的价格与金额不变。")
        } catch {
            catalogMessage = language.text("Catalog rejected. Check signature, revision and price versions. Existing prices are unchanged.",
                                           "价格表被拒绝，请检查签名、版本序号和价格版本。现有价格未改动。")
        }
    }
}

/// Set the name on the actual native editor, not only on a SwiftUI wrapper.
/// This keeps its path value, accessible name and keyboard focus together.
private struct AccessibleExecutablePathField: NSViewRepresentable {
    @Binding var text: String
    let language: AppLanguage

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("health.executableOverride")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = language.text("Empty = automatic discovery", "留空则自动查找")
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.textField)
        field.setAccessibilityLabel(language.text("Codex executable override; restart required", "自定义 Codex 可执行文件；重启生效"))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
