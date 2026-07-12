import AppKit
import CodexUsageUI
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private var panelController: TransparentUsagePanelController!
    private var storeObserver: AnyCancellable?

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        panelController = TransparentUsagePanelController(
            store: store,
            statusItem: statusItem,
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
        storeObserver?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Codex 用量"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        button.target = self
        button.action = #selector(handleStatusItemAction)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Codex 用量"
    }

    private func observeUsageChanges() {
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusButton()
            }
        }
    }

    private func updateStatusButton() {
        statusItem.button?.title = " \(store.menuPercent)%"
        statusItem.button?.setAccessibilityLabel("Codex 剩余额度 \(store.menuPercent)%")
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
        let refresh = NSMenuItem(title: "刷新用量", action: #selector(refreshUsage), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Codex 用量", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func refreshUsage() {
        Task { await store.refresh() }
    }

    @objc
    private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
