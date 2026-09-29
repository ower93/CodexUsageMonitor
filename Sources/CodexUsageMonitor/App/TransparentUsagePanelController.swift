import AppKit
import CodexUsageUI
import SwiftUI

private final class TransparentUsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TransparentUsagePanelController {
    private enum Layout {
        static let width = UsagePanelMetrics.width
        static let height = UsagePanelMetrics.height
        static let cornerRadius: CGFloat = 28
        static let statusBarGap: CGFloat = 8
        static let screenMargin: CGFloat = 8
    }

    private let panel: TransparentUsagePanel
    private let tuning: GlassTuning
    private weak var statusItem: NSStatusItem?
    private let refresh: () -> Void
    private let visibilityDidChange: (Bool) -> Void
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    init(
        store: UsageStore,
        statusItem: NSStatusItem,
        refresh: @escaping () -> Void,
        visibilityDidChange: @escaping (Bool) -> Void
    ) {
        self.statusItem = statusItem
        self.refresh = refresh
        self.visibilityDidChange = visibilityDidChange
        tuning = .final
        panel = TransparentUsagePanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel(store: store)
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func tearDown() {
        close()
        removeEventMonitors()
    }

    private func removeEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        globalEventMonitor = nil
        localEventMonitor = nil
    }

    private func configurePanel(store: UsageStore) {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.cornerRadius = Layout.cornerRadius
        rootView.layer?.cornerCurve = .continuous
        rootView.layer?.masksToBounds = true

        let blurView = NSVisualEffectView(frame: rootView.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .underWindowBackground
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.isEmphasized = false
        blurView.alphaValue = tuning.backgroundBlurPercent / 100
        rootView.addSubview(blurView)

        let hostingView = NSHostingView(
            rootView: UsagePanelView(
                store: store,
                tuning: tuning,
                onRefresh: refresh,
                onHeightChange: { [weak self] height in
                    self?.resizePanel(to: height)
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.addSubview(hostingView)
        panel.contentView = rootView
    }

    private func resizePanel(to height: CGFloat) {
        let height = min(UsagePanelMetrics.height, max(135, height.rounded()))
        guard abs(panel.frame.height - height) > 0.5 else { return }

        var frame = panel.frame
        if panel.isVisible {
            frame.origin.y += frame.height - height
        }
        frame.size.height = height
        panel.setFrame(frame, display: panel.isVisible, animate: panel.isVisible)
        panel.invalidateShadow()
    }

    private func show() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        visibilityDidChange(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.installEventMonitors()
        }
    }

    private func close() {
        if panel.isVisible {
            panel.orderOut(nil)
            visibilityDidChange(false)
        }
        removeEventMonitors()
    }

    private func positionPanel() {
        guard
            let button = statusItem?.button,
            let buttonWindow = button.window
        else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero

        var x = buttonFrameOnScreen.midX - Layout.width / 2
        x = max(visibleFrame.minX + Layout.screenMargin, x)
        x = min(visibleFrame.maxX - Layout.width - Layout.screenMargin, x)

        var y = buttonFrameOnScreen.minY - panel.frame.height - Layout.statusBarGap
        if y < visibleFrame.minY + Layout.screenMargin {
            y = buttonFrameOnScreen.maxY + Layout.statusBarGap
        }
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func installEventMonitors() {
        guard globalEventMonitor == nil, localEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.window !== self.panel, event.window !== self.statusItem?.button?.window {
                self.close()
            }
            return event
        }
    }
}
