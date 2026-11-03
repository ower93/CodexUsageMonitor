import AppKit

/// The app uses an AppKit lifecycle rather than SwiftUI's App/Scene commands.
/// Standard text shortcuts therefore need a native Edit menu. Nil targets let
/// AppKit validate and route each action to the currently focused editor.
@MainActor
public enum UsageApplicationMenu {
    public static func make(language: AppLanguage) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(title: language.appTitle, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: language.appTitle)
        appMenu.addItem(NSMenuItem(title: language.quitApplication,
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileTitle = language == .english ? "File" : "文件"
        let fileItem = NSMenuItem(title: fileTitle, action: nil, keyEquivalent: "")
        let file = NSMenu(title: fileTitle)
        file.addItem(NSMenuItem(title: language == .english ? "Close Window" : "关闭窗口",
                               action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = file
        main.addItem(fileItem)

        let editTitle = language == .english ? "Edit" : "编辑"
        let editItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let edit = NSMenu(title: editTitle)
        func add(_ english: String, _ chinese: String, action: Selector, key: String,
                 modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: language == .english ? english : chinese,
                                  action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add("Undo", "撤销", action: Selector(("undo:")), key: "z")
        add("Redo", "重做", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "剪切", action: #selector(NSText.cut(_:)), key: "x")
        add("Copy", "复制", action: #selector(NSText.copy(_:)), key: "c")
        add("Paste", "粘贴", action: #selector(NSText.paste(_:)), key: "v")
        add("Select All", "全选", action: #selector(NSText.selectAll(_:)), key: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
