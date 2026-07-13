import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var language: AppLanguage
    private let client = CodexAppServerClient()
    private let previewOnly: Bool
    private var lastLiveUsage: CodexLiveUsage?
    private var lastRefreshError: Error?

    public init(
        autoRefresh: Bool = true,
        previewOnly: Bool = false,
        language: AppLanguage? = nil
    ) {
        let selectedLanguage = language ?? AppLanguage.resolveAndPersist()
        self.previewOnly = previewOnly
        self.language = selectedLanguage
        snapshot = .preview(language: selectedLanguage)
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
            return language.demoStatus
        }
        return lastError == nil ? language.liveStatus : language.failureStatus
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: AppLanguage.storageKey)
        if let lastLiveUsage {
            snapshot = UsageSnapshot(live: lastLiveUsage, language: newLanguage)
        } else {
            snapshot = .preview(language: newLanguage)
        }
        if let lastRefreshError {
            lastError = Self.errorDescription(lastRefreshError, language: newLanguage)
        }
    }

    public func refresh() async {
        guard !previewOnly else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let liveUsage = try await client.fetchUsage()
            lastLiveUsage = liveUsage
            snapshot = UsageSnapshot(live: liveUsage, language: language)
            lastRefreshError = nil
            lastError = nil
        } catch {
            lastRefreshError = error
            lastError = Self.errorDescription(error, language: language)
        }
    }

    private static func errorDescription(_ error: Error, language: AppLanguage) -> String {
        if let clientError = error as? CodexUsageClientError {
            return clientError.description(language: language)
        }
        return error.localizedDescription
    }
}
