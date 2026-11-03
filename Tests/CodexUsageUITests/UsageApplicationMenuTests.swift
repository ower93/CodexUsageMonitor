import AppKit
import Testing
@testable import CodexUsageUI

struct UsageApplicationMenuTests {
    @Test @MainActor
    func standardEditingCommandsRouteToFirstResponderInBothLanguages() throws {
        for language in AppLanguage.allCases {
            let main = UsageApplicationMenu.make(language: language)
            let edit = try #require(main.items.last?.submenu)
            #expect(edit.autoenablesItems)
            let commands = edit.items.filter { !$0.isSeparatorItem }
            #expect(commands.count == 6)
            let actions = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]
            let keys = ["z", "z", "x", "c", "v", "a"]
            for (index, item) in commands.enumerated() {
                #expect(item.action == NSSelectorFromString(actions[index]))
                #expect(item.keyEquivalent == keys[index])
                #expect(item.target == nil)
                #expect(item.keyEquivalentModifierMask == (index == 1 ? [.command, .shift] : .command))
            }
            #expect(edit.title == (language == .english ? "Edit" : "编辑"))
            #expect(commands.last?.title == (language == .english ? "Select All" : "全选"))
        }
    }

    @Test @MainActor
    func closingAWindowDoesNotInvokeApplicationTermination() throws {
        for language in AppLanguage.allCases {
            let main = UsageApplicationMenu.make(language: language)
            let close = try #require(main.items.dropFirst().first?.submenu?.items.first)
            #expect(close.action == #selector(NSWindow.performClose(_:)))
            #expect(close.keyEquivalent == "w")
            #expect(close.keyEquivalentModifierMask == .command)
            #expect(close.target == nil)
            #expect(close.title == (language == .english ? "Close Window" : "关闭窗口"))
        }
    }

    @Test @MainActor
    func quitUsesTheApplicationsNormalTerminationPath() throws {
        let main = UsageApplicationMenu.make(language: .english)
        let quit = try #require(main.items.first?.submenu?.items.first)
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
        #expect(quit.target == nil)
        #expect(quit.title == AppLanguage.english.quitApplication)
    }
}
