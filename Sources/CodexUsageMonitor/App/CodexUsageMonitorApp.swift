import AppKit
import CodexUsageUI
import Combine
import Darwin
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lifecycle = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.kevinchen.CodexUsageMonitor", category: "Lifecycle")
    private let store = UsageStore(autoRefresh: false, previewOnly: CommandLine.arguments.contains("--demo"))
    private var refreshCoordinator: UsageRefreshCoordinator?
    private var statusBarController: StatusBarController?
    private var terminationTask: Task<Void, Never>?
    private var lifecycleObserver: UsageLifecycleObserver?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var menuLanguageObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility Inspector's target menu excludes accessory apps.
        // Only the explicit synthetic-data QA launch may show a Dock entry.
        let inspectableDemo = store.isDemo && CommandLine.arguments.contains("--qa-regular-app")
        NSApp.setActivationPolicy(inspectableDemo ? .regular : .accessory)
        menuLanguageObserver = store.$language.removeDuplicates().sink { language in
            NSApp.mainMenu = UsageApplicationMenu.make(language: language)
        }
        // Terminal/build tooling sends SIGTERM, which otherwise bypasses
        // AppKit's termination delegate and can orphan the Codex helper.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    // terminateLater enters AppKit's nested run loop. Calling
                    // terminate inside a Swift MainActor task can prevent the
                    // async cleanup task from ever starting. A run-loop selector
                    // invokes it after this dispatch callback has returned.
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                }
            }
            source.resume()
            terminationSignals.append(source)
        }
        if store.isDemo || ProcessInfo.processInfo.environment["CODEX_USAGE_DATA_DIR"] != nil {
            if CommandLine.arguments.contains("--qa-light") { NSApp.appearance = NSAppearance(named: .aqua) }
            if CommandLine.arguments.contains("--qa-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        // Accelerated profiling is allowed only with an explicitly isolated
        // data directory, never the normal user's ledger by accident.
        let isProfiling = CommandLine.arguments.contains("--qa-profile")
            && ProcessInfo.processInfo.environment["CODEX_USAGE_DATA_DIR"] != nil
        let coordinator = UsageRefreshCoordinator(store: store,
            liveRefreshInterval: .seconds(isProfiling ? 10 : 60),
            costRefreshInterval: .seconds(isProfiling ? 30 : 900))
        refreshCoordinator = coordinator
        statusBarController = StatusBarController(
            store: store,
            refresh: { [weak coordinator] in
                Task { @MainActor in
                    await coordinator?.refreshNow()
                }
            }
        )
        if !store.isDemo {
            lifecycleObserver = UsageLifecycleObserver(coordinator: coordinator)
            coordinator.start()
        }
        if CommandLine.arguments.contains("--analytics") { statusBarController?.openAnalytics() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.info("Termination requested")
        guard terminationTask == nil else { return .terminateLater }
        guard let refreshCoordinator else { return .terminateNow }

        terminationTask = Task { @MainActor [weak self] in
            self?.lifecycle.info("Stopping refresh coordinator")
            self?.lifecycleObserver?.stop()
            self?.lifecycleObserver = nil
            await refreshCoordinator.stop()
            self?.refreshCoordinator = nil
            self?.lifecycle.info("Refresh coordinator stopped; allowing termination")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.info("Application will terminate")
        lifecycleObserver?.stop()
        terminationSignals.forEach { $0.cancel() }
        menuLanguageObserver?.cancel()
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
