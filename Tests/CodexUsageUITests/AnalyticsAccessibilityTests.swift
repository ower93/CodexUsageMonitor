import AppKit
import SwiftUI
import Testing
@testable import CodexUsageUI

/// Inspect only views owned by this test process, using AppKit's public
/// accessibility getters. No remote-app AX access or system permission changes.
@Suite(.serialized)
struct AnalyticsAccessibilityTests {
    @Test @MainActor
    func dataHealthExposesNamedValuesInBothLanguages() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_USAGE_NATIVE_AX_TESTS"] == "1" else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for language in AppLanguage.allCases {
            let store = UsageStore(autoRefresh: false, previewOnly: true, language: language)
            let root = AnalyticsHealthView(usage: store, analytics: AnalyticsStore(previewData: .demo()), privacy: true, scrolls: false)
            let host = NSHostingView(rootView: root.environment(\.accessibilityEnabled, true).frame(width: 940, height: 900))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 900),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let elements = try inspect(host)
            let required = ["source.limits", "source.account", "source.threads", "source.cost",
                            "files", "unchanged", "usageFiles", "issues", "home", "catalogDate", "catalogRevision", "importedAt"]
            for identifier in required {
                let row = try #require(elements["health." + identifier], "Missing accessible metric: \(identifier)")
                try #require(!row.label.isEmpty, "Metric has a name: \(identifier)")
                try #require(!row.value.isEmpty, "Metric has a value: \(identifier)")
            }
            #expect(elements["health.home"]?.value == language.text("Hidden", "已隐藏"))
            #expect(elements["health.executableOverride"] == nil)
            #expect(elements["health.files"]?.value == "0 / 0")
            print("NATIVE_HEALTH_AX language=\(language.rawValue) requiredMetrics=\(required.count) privacyProtected=true")
        }
    }

    @Test @MainActor
    func executableOverrideHasAccessibleNameAndNativeKeyboardFocus() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_USAGE_NATIVE_AX_TESTS"] == "1" else { return }
        _ = NSApplication.shared
        let suite = "health-keyboard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("/test/codex", forKey: CodexEnvironment.executableOverrideKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(autoRefresh: false, previewOnly: true, language: .english, defaults: defaults)
        let root = AnalyticsHealthView(usage: store, analytics: AnalyticsStore(previewData: .demo()), privacy: false, scrolls: false)
        let host = NSHostingView(rootView: root.defaultAppStorage(defaults)
            .environment(\.accessibilityEnabled, true).frame(width: 940, height: 1000))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 1000),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        var views: [NSView] = [host]
        var editable: [NSTextField] = []
        while let view = views.popLast() {
            if let field = view as? NSTextField, field.isEditable { editable.append(field) }
            views.append(contentsOf: view.subviews)
        }
        // NSViewRepresentable editors are owned native controls; inspect that
        // control directly. The hosting view's in-process virtual AX getter
        // does not traverse through its representable bridge on every OS.
        let control = try #require(editable.first { $0.accessibilityIdentifier() == "health.executableOverride" })
        #expect(control.isAccessibilityElement())
        #expect(control.accessibilityRole() == .textField)
        #expect(control.accessibilityLabel()?.contains("Codex executable override") == true)
        #expect(control.accessibilityValue() as? String == "/test/codex")
        #expect(window.makeFirstResponder(control))
        #expect(control.currentEditor() != nil)
        #expect(window.makeFirstResponder(nil))
        control.stringValue = "/test/updated-codex"
        control.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        #expect(defaults.string(forKey: CodexEnvironment.executableOverrideKey) == "/test/updated-codex")
        print("NATIVE_HEALTH_KEYBOARD editableFieldNamed=true focusAndResign=true")
    }

    @MainActor private func inspect(_ root: NSObject) throws -> [String: Metric] {
        var stack = [root]
        var visited = Set<ObjectIdentifier>()
        var result: [String: Metric] = [:]
        while let node = stack.popLast() {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            try #require(visited.count <= 5_000, "Accessibility tree is bounded")
            if let identifier = getter(node, "accessibilityIdentifier") as? String {
                let rawValue = getter(node, "accessibilityValue")
                result[identifier] = Metric(label: getter(node, "accessibilityLabel") as? String ?? "",
                                            value: rawValue as? String ?? (rawValue as? NSAttributedString)?.string ?? "")
            }
            for relationship in ["accessibilityChildren", "accessibilityContents", "accessibilityVisibleChildren"] {
                if let children = getter(node, relationship) as? [NSObject] {
                    stack.append(contentsOf: children.reversed())
                }
            }
        }
        return result
    }

    @MainActor private func getter(_ node: NSObject, _ selector: String) -> Any? {
        let selector = NSSelectorFromString(selector)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    private struct Metric: Equatable { let label: String; let value: String }
}
