import Combine
import Foundation

@MainActor
final class AnalyticsStore: ObservableObject {
    @Published var filter: AnalyticsFilter {
        didSet {
            selectedDay = nil
            if let value = try? JSONEncoder().encode(filter) { defaults.set(value, forKey: "analytics.filters.v2") }
        }
    }
    @Published var selectedDay: String?
    @Published private(set) var data = AnalyticsData()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let database: AnalyticsDatabase
    private let isPreview: Bool

    init(defaults: UserDefaults = .standard, databaseURL: URL = AnalyticsDatabase.defaultURL, previewData: AnalyticsData? = nil) {
        self.defaults = defaults
        database = AnalyticsDatabase(url: databaseURL)
        isPreview = previewData != nil
        filter = defaults.data(forKey: "analytics.filters.v2").flatMap { try? JSONDecoder().decode(AnalyticsFilter.self, from: $0) } ?? AnalyticsFilter()
        if let previewData {
            data = previewData
            filter = AnalyticsFilter()
            filter.period = .last30Days
        }
    }

    var result: AnalyticsResult { AnalyticsEngine.summarize(data, filter: filter) }
    var focusedResult: AnalyticsResult {
        guard let selectedDay else { return result }
        var selected = filter
        selected.period = .custom
        selected.customStart = selectedDay
        selected.customEnd = selectedDay
        return AnalyticsEngine.summarize(data, filter: selected)
    }

    func reload() async {
        guard !isLoading, !isPreview else { return }
        isLoading = true
        defer { isLoading = false }
        let database = database
        let worker = Task.detached(priority: .utility) { try database.read() }
        do {
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            data = value
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "analytics-database-unavailable"
        }
    }
}
