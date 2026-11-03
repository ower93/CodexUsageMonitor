import Foundation
import OSLog

enum UsageTelemetry {
    static let scans = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.kevinchen.CodexUsageMonitor", category: "LocalIngestion")
    static let connection = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.kevinchen.CodexUsageMonitor", category: "Connection")
    static let lifecycle = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.kevinchen.CodexUsageMonitor", category: "RefreshLifecycle")
}
