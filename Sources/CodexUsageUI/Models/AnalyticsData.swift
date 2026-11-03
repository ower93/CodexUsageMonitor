import Foundation

struct AnalyticsSession: Codable, Hashable, Sendable {
    let id: String
    var parentID: String?
    var title: String
}

struct AnalyticsRecord: Identifiable, Sendable {
    let id: Int64
    let value: APICostLedger.Record
}

struct AnalyticsData: Sendable {
    var records: [AnalyticsRecord] = []
    var sessions: [String: AnalyticsSession] = [:]
    var importedAt: Date?

    func rootID(for sessionID: String) -> String {
        var current = sessionID
        var path = [sessionID]
        var seen: Set<String> = [sessionID]
        while let parent = sessions[current]?.parentID, !seen.contains(parent) {
            current = parent
            seen.insert(parent)
            path.append(parent)
        }
        // Cyclic metadata is invalid: avoid assigning the same family
        // inconsistently by selecting a stable representative of the cycle.
        if let parent = sessions[current]?.parentID, let offset = path.firstIndex(of: parent) {
            return path[offset...].sorted().first ?? sessionID
        }
        return current
    }
}
