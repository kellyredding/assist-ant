import AppKit

/// Builds and manages the application's menu bar (the menu strip at the top
/// of the screen, distinct from the status item in the menu bar's right
/// side). Programmatic NSMenu construction, mirroring Galaxy's pattern
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/MainMenu.swift).
///
/// Routes menu item actions through MenuActions.shared, which posts named
/// NSNotifications. AppDelegate observes those notifications and dispatches
/// to the right subsystem. The indirection lets new menu items slot in
/// without AppDelegate having to know about every menu wiring.
final class MainMenu: NSObject {
    func install() {
        let mainMenu = NSMenu()

        // Application menu — title is the app name and gets used by macOS
        // for the bold "Assist Ant" label at the left of the menu bar.
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        buildAppMenu(appMenu)

        // File menu — currently just "Close Window" so ⌘W has a home.
        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem(
            title: "File", action: nil, keyEquivalent: ""
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        buildFileMenu(fileMenu)

        // Window menu — AppKit auto-populates with Minimize, Zoom, Bring
        // All to Front, and the list of open windows when we set
        // NSApp.windowsMenu.
        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem(
            title: "Window", action: nil, keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - App menu

    private func buildAppMenu(_ menu: NSMenu) {
        // The presented app name. The executable (and thus processName)
        // is "AssistAnt"; the user-facing name is "Assist Ant", matching
        // CFBundleDisplayName.
        let appName = "Assist Ant"

        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuActions.showPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = MenuActions.shared
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
    }

    // MARK: - File menu

    private func buildFileMenu(_ menu: NSMenu) {
        // Close Window (⌘W) — first responder routes this to the key window
        // via performClose:, which the window's red close button also uses.
        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(closeItem)
    }
}

// MARK: - MenuActions

/// Shared @objc target for menu items. Each method here posts an
/// NSNotification with a known name. AppDelegate observes those notifications
/// and dispatches to the right subsystem. The indirection matches Galaxy's
/// MenuActions pattern and keeps menu wiring decoupled from app subsystems.
final class MenuActions: NSObject {
    static let shared = MenuActions()

    private override init() { super.init() }

    @objc func showPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .showPreferences, object: nil)
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showPreferences = Notification.Name("showPreferences")
}
