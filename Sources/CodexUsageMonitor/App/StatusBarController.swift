import AppKit
import CodexUsageUI
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let refresh: () -> Void
    private let statusItem: NSStatusItem
    private var panelController: TransparentUsagePanelController!
    private var analyticsController: AnalyticsWindowController?
    private var storeObserver: AnyCancellable?
    private let updater: AppUpdateController

    init(store: UsageStore, refresh: @escaping () -> Void) {
        self.store = store
        self.refresh = refresh
        updater = AppUpdateController(enabled: !store.isDemo)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        panelController = TransparentUsagePanelController(
            store: store,
            statusItem: statusItem,
            refresh: refresh,
            openAnalytics: { [weak self] in self?.openAnalytics() },
            visibilityDidChange: { [weak self] isVisible in
                self?.statusItem.button?.highlight(isVisible)
            }
        )
        configureStatusButton()
        observeUsageChanges()
        updateStatusButton()
    }

    func tearDown() {
        panelController.tearDown()
        analyticsController?.close()
        analyticsController = nil
        storeObserver?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: store.language.appTitle
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        button.target = self
        button.action = #selector(handleStatusItemAction)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = store.language.appTitle
    }

    private func observeUsageChanges() {
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusButton()
            }
        }
    }

    private func updateStatusButton() {
        statusItem.button?.title = " \(store.menuText)"
        statusItem.button?.toolTip = store.language.appTitle
        statusItem.button?.setAccessibilityLabel(
            store.menuPercent.map { store.language.remainingAccessibilityLabel(percent: $0) } ?? store.statusText
        )
    }

    @objc
    private func handleStatusItemAction() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(
            title: store.language.refreshUsage,
            action: #selector(refreshUsage),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)
        let analytics = NSMenuItem(title: store.language == .english ? "Open Analytics…" : "打开用量分析…",
                                   action: #selector(openAnalytics), keyEquivalent: "a")
        analytics.target = self
        menu.addItem(analytics)
        menu.addItem(updater.menuItem(english: store.language == .english))
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: store.language.quitApplication,
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func refreshUsage() {
        refresh()
    }

    @objc func openAnalytics() {
        if analyticsController == nil { analyticsController = AnalyticsWindowController(store: store, refresh: refresh) }
        analyticsController?.show()
    }

    @objc
    private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
