import AppKit
import CodexUsageUI
import SwiftUI

/// This AppKit-lifecycle menu utility uses one standard NSWindow as a narrow
/// hosting boundary. Content, navigation, filters and selection stay in SwiftUI.
@MainActor
final class AnalyticsWindowController {
    private let window: NSWindow

    init(store: UsageStore, refresh: @escaping () -> Void) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(1120, visible.width - 40)
        let height = min(790, visible.height - 40)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Usage · Analytics"
        window.contentMinSize = NSSize(width: min(780, width), height: min(520, height))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: AnalyticsRootView(store: store, refresh: refresh))
        window.setFrameAutosaveName("CodexUsageAnalyticsV2")
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}
