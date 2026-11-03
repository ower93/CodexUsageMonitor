import Foundation
import Testing
@testable import CodexUsageUI

struct CodexEnvironmentTests {
    @Test
    func usesExplicitCodexHomeAndDefaultFallback() {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        #expect(CodexEnvironment.home(environment: [:], userHome: home).path == "/tmp/test-home/.codex")
        #expect(CodexEnvironment.home(environment: ["CODEX_HOME": "/tmp/custom-codex"], userHome: home).path == "/tmp/custom-codex")
        #expect(CodexEnvironment.home(environment: ["CODEX_HOME": "  "], userHome: home).path == "/tmp/test-home/.codex")
    }

    @Test
    func executableOverrideIsExplicitAndCanBeCleared() throws {
        let name = "CodexEnvironmentTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CodexEnvironment.executableOverride(defaults: defaults) == nil)
        defaults.set(" /tmp/custom-codex ", forKey: CodexEnvironment.executableOverrideKey)
        #expect(CodexEnvironment.executableOverride(defaults: defaults)?.path == "/tmp/custom-codex")
        defaults.set("", forKey: CodexEnvironment.executableOverrideKey)
        #expect(CodexEnvironment.executableOverride(defaults: defaults) == nil)
    }
}
