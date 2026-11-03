import AppKit
import CodexUsageUI
import Foundation
import SwiftUI

@main
@MainActor
struct PreviewRendererTool {
    static func main() async throws {
        _ = NSApplication.shared

        let arguments = Array(CommandLine.arguments.dropFirst())
        let outputPath = arguments.first(where: { !$0.hasPrefix("--") })
            ?? "work/codex-usage-panel-preview.png"
        let showsSettings = arguments.contains("--settings")
        let language: AppLanguage = arguments.contains("--english") ? .english : .simplifiedChinese
        let dark = arguments.contains("--dark")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if arguments.contains("--analytics") || arguments.contains("--share-card") || arguments.contains("--health") {
            let data: Data
            if arguments.contains("--health") {
                data = try await UsagePreviewExport.health(language: language, dark: dark)
            } else if arguments.contains("--analytics") {
                data = try await UsagePreviewExport.analytics(language: language, dark: dark)
            } else {
                data = try UsagePreviewExport.shareCard(language: language)
            }
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            return
        }
        let store = UsageStore(autoRefresh: false, previewOnly: !arguments.contains("--empty"), language: language)
        let height: CGFloat = arguments.contains("--compact") ? 520
            : (arguments.contains("--full") ? 900 : UsagePanelMetrics.height)
        store.panelMaximumHeight = height
        let tuning = GlassTuning.final
        let content = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.72, green: 0.84, blue: 0.96),
                    Color(red: 0.34, green: 0.45, blue: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            UsagePanelView(
                store: store,
                tuning: tuning,
                preferencesEnabled: false,
                settingsInitiallyPresented: showsSettings,
                onOpenAnalytics: {},
                previewHeight: height
            )
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: UsagePanelMetrics.width, height: height)
        let png = try await UsagePreviewExport.render(content,
            size: NSSize(width: UsagePanelMetrics.width, height: height), dark: dark)
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

private enum PreviewError: Error {
    case renderFailed
}
