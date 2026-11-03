import Foundation

/// Read-only configuration of source paths. Never discovers or copies secrets.
enum CodexEnvironment {
    static let executableOverrideKey = "codex.executableOverride"

    static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["CODEX_HOME"], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    static var sessionRoots: [URL] {
        ["sessions", "archived_sessions"].map { home().appendingPathComponent($0, isDirectory: true) }
    }

    static func executableOverride(defaults: UserDefaults = .standard) -> URL? {
        guard let value = defaults.string(forKey: executableOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}
