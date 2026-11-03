import AppKit
import SwiftUI

/// Deterministic, privacy-safe documentation assets from the real SwiftUI views.
/// This renderer never requests live account data or reads a production ledger.
@MainActor
public enum UsagePreviewExport {
    public static func health(language: AppLanguage, dark: Bool = false) async throws -> Data {
        let store = UsageStore(autoRefresh: false, previewOnly: true, language: language)
        let content = AnalyticsHealthView(usage: store, analytics: AnalyticsStore(previewData: .demo()), privacy: true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 940, height: 900)
        return try await render(content, size: NSSize(width: 940, height: 900), dark: dark)
    }

    public static func analytics(language: AppLanguage, dark: Bool = false) async throws -> Data {
        let store = UsageStore(autoRefresh: false, previewOnly: true, language: language)
        let content = AnalyticsRootView(store: store, refresh: {})
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 1120, height: 840)
        return try await render(content, size: NSSize(width: 1120, height: 840), dark: dark)
    }

    public static func render<Content: View>(_ content: Content, size: NSSize, dark: Bool) async throws -> Data {
        // ScrollView/Table are backed by AppKit and cannot be exported by
        // ImageRenderer. Attach the actual hosting view to a temporary native
        // window and give SwiftUI a layout turn before caching its pixels.
        NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.rendering }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.rendering }
        return png
    }

    public static func shareCard(language: AppLanguage) throws -> Data {
        var filter = AnalyticsFilter()
        filter.period = .last30Days
        return try AnalyticsExportPanel.renderImage(AnalyticsEngine.summarize(.demo(), filter: filter), language: language)
    }

    private enum Failure: Error { case rendering }
}
