import AppKit

/// SwiftPM/AppKit apps don't receive SwiftUI's automatic Edit menu. Without this, standard
/// field-editor shortcuts can disappear in our nonactivating panel and the settings windows.
@MainActor enum AppMenus {
    static func install() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Command Space")
        app.submenu?.addItem(withTitle: "About Command Space", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Command Space", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }
}
