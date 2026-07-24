import AppKit
import CodexUsageUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore(autoRefresh: false)
    private var refreshCoordinator: UsageRefreshCoordinator?
    private var statusBarController: StatusBarController?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let coordinator = UsageRefreshCoordinator(store: store)
        refreshCoordinator = coordinator
        statusBarController = StatusBarController(
            store: store,
            refresh: { [weak coordinator] in
                Task { @MainActor in
                    await coordinator?.refreshNow()
                }
            }
        )
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard let refreshCoordinator else { return .terminateNow }

        terminationTask = Task { @MainActor [weak self] in
            await refreshCoordinator.stop()
            self?.refreshCoordinator = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.tearDown()
        statusBarController = nil
    }
}

@main
enum CodexUsageMonitorApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
