import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    private let client = CodexAppServerClient()
    private let previewOnly: Bool

    public init(autoRefresh: Bool = true, previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        snapshot = .preview
        if autoRefresh, !previewOnly {
            Task { [weak self] in
                await self?.refresh()
            }
        }
    }

    public var menuPercent: Int {
        snapshot.periods.first?.remainingPercent ?? 0
    }

    public var statusText: String {
        if previewOnly {
            return "演示数据 · 隐私保护"
        }
        return lastError == nil ? "真实账户 · 实时刷新" : "刷新失败 · 点击重试"
    }

    public func refresh() async {
        guard !previewOnly else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let liveUsage = try await client.fetchUsage()
            snapshot = UsageSnapshot(live: liveUsage)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
