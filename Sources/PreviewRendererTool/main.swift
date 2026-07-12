import AppKit
import CodexUsageUI
import Foundation
import SwiftUI

@main
@MainActor
struct PreviewRendererTool {
    static func main() async throws {
        _ = NSApplication.shared

        let outputPath = CommandLine.arguments.dropFirst().first
            ?? "work/codex-usage-panel-preview.png"
        let store = UsageStore(autoRefresh: false, previewOnly: true)
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
            UsagePanelView(store: store, tuning: tuning)
        }
        .frame(width: UsagePanelMetrics.width, height: UsagePanelMetrics.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw PreviewError.renderFailed
        }

        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

private enum PreviewError: Error {
    case renderFailed
}
