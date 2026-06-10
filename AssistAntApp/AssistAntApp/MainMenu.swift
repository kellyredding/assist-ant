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

        // Edit menu — standard text-editing actions. The items target the
        // first responder (nil target), so AppKit dispatches them down the
        // responder chain to the focused terminal surface, which implements
        // the NSText editing selectors. Without this menu ⌘V has no home and
        // never reaches the terminal, so pasting silently fails. Mirrors
        // Galaxy's Edit menu.
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(
            title: "Edit", action: nil, keyEquivalent: ""
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        buildEditMenu(editMenu)

        // View menu — switches the main window's right-pane tab. Mirrors
        // Galaxy's View ▸ Previous/Next view (⌘H/⌘← and ⌘L/⌘→).
        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem(
            title: "View", action: nil, keyEquivalent: ""
        )
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        buildViewMenu(viewMenu)

        // Agent menu — terminal font zoom plus the session-acting Clear /
        // Compact commands sent to the embedded session's PTY. AssistAnt's
        // analog of Galaxy's Sessions menu. Font items gate on the terminal
        // holding focus; Clear / Compact gate on the session running (both
        // via validateMenuItem).
        let agentMenu = NSMenu(title: "Agent")
        let agentMenuItem = NSMenuItem(
            title: "Agent", action: nil, keyEquivalent: ""
        )
        agentMenuItem.submenu = agentMenu
        mainMenu.addItem(agentMenuItem)
        buildAgentMenu(agentMenu)

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

        // Hide deliberately has no ⌘H: that shortcut is reassigned to View ▸
        // Previous view (matching Galaxy). Hide stays reachable from the menu.
        let hideItem = NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: ""
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

    // MARK: - Edit menu

    private func buildEditMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo",
                     action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    // MARK: - View menu

    /// Previous/Next view switch the main window's right-pane tab. Each has a
    /// letter binding (⌘H/⌘L) plus a hidden arrow alternate (⌘←/⌘→), matching
    /// Galaxy. Enable state is gated dynamically by validateMenuItem.
    private func buildViewMenu(_ menu: NSMenu) {
        let prev = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: "h"
        )
        prev.target = MenuActions.shared
        menu.addItem(prev)

        let prevArrow = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevArrow.target = MenuActions.shared
        prevArrow.keyEquivalentModifierMask = .command
        prevArrow.isAlternate = true
        menu.addItem(prevArrow)

        let next = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: "l"
        )
        next.target = MenuActions.shared
        menu.addItem(next)

        let nextArrow = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextArrow.target = MenuActions.shared
        nextArrow.keyEquivalentModifierMask = .command
        nextArrow.isAlternate = true
        menu.addItem(nextArrow)
    }

    // MARK: - Agent menu

    private func buildAgentMenu(_ menu: NSMenu) {
        // Terminal font size on top. Enable state is computed dynamically
        // by validateMenuItem — gated on the agent terminal holding first
        // responder. No explicit modifier mask: the items take AppKit's
        // default (.command), matching Galaxy.
        let defaultItem = NSMenuItem(
            title: "Default terminal font size",
            action: #selector(MenuActions.defaultTerminalFontSize(_:)),
            keyEquivalent: "0"
        )
        defaultItem.target = MenuActions.shared
        menu.addItem(defaultItem)

        let biggerItem = NSMenuItem(
            title: "Bigger",
            action: #selector(MenuActions.biggerTerminalFontSize(_:)),
            keyEquivalent: "="
        )
        biggerItem.target = MenuActions.shared
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(
            title: "Smaller",
            action: #selector(MenuActions.smallerTerminalFontSize(_:)),
            keyEquivalent: "-"
        )
        smallerItem.target = MenuActions.shared
        menu.addItem(smallerItem)

        menu.addItem(.separator())

        // Scrollback (⌘S) opens the read-only scrollback overlay over the
        // live terminal. No explicit modifier mask: takes AppKit's default
        // (.command), matching Galaxy. Enable state is gated dynamically by
        // validateMenuItem on the session running.
        let scrollbackItem = NSMenuItem(
            title: "Scrollback",
            action: #selector(MenuActions.enterScrollback(_:)),
            keyEquivalent: "s"
        )
        scrollbackItem.target = MenuActions.shared
        menu.addItem(scrollbackItem)

        // Trim Buffer (⌃⌘K) drops the scrollback and reflows the viewport;
        // Reflow Buffer (⌃L) redraws the current screen without trimming.
        // Both ride the Galactic TerminalBackend buffer extension and gate
        // on the agent terminal holding focus (validateMenuItem). Titles and
        // bindings copied from Galaxy's Sessions menu — ⌃L coexists with the
        // View ▸ Next view ⌘L since the modifiers differ.
        let trimBufferItem = NSMenuItem(
            title: "Trim Buffer",
            action: #selector(MenuActions.trimBuffer(_:)),
            keyEquivalent: "k"
        )
        trimBufferItem.target = MenuActions.shared
        trimBufferItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(trimBufferItem)

        let reflowBufferItem = NSMenuItem(
            title: "Reflow Buffer",
            action: #selector(MenuActions.reflowBuffer(_:)),
            keyEquivalent: "l"
        )
        reflowBufferItem.target = MenuActions.shared
        reflowBufferItem.keyEquivalentModifierMask = [.control]
        menu.addItem(reflowBufferItem)

        menu.addItem(.separator())

        // Clear / Compact send the slash command to the embedded session.
        // Bindings copied verbatim from Galaxy: Delete (0x08) with the
        // command+shift / command+control masks. Enable state is gated
        // dynamically by validateMenuItem on the session running.
        let clearItem = NSMenuItem(
            title: "Clear session",
            action: #selector(MenuActions.clearSession(_:)),
            keyEquivalent: ""
        )
        clearItem.target = MenuActions.shared
        clearItem.keyEquivalent = "\u{08}"  // Delete key
        clearItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(clearItem)

        let compactItem = NSMenuItem(
            title: "Compact session",
            action: #selector(MenuActions.compactSession(_:)),
            keyEquivalent: ""
        )
        compactItem.target = MenuActions.shared
        compactItem.keyEquivalent = "\u{08}"  // Delete key
        compactItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(compactItem)
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

    // MARK: - View menu actions

    /// View ▸ Previous / Next view. Switches the main window's right-pane
    /// tab. Calls the navigator directly (no notification indirection), like
    /// the font-size actions below.
    @objc func previousView(_ sender: Any?) {
        MainTabNavigator.shared.switchToPreviousTab()
    }

    @objc func nextView(_ sender: Any?) {
        MainTabNavigator.shared.switchToNextTab()
    }

    /// View ▸ Default / Bigger / Smaller terminal font size. Unlike the
    /// notification-posting actions above, these call the controller
    /// directly — mirroring Galaxy, whose font actions call
    /// `focusedTerminalPane()?.increaseFontSize()` directly. The focus
    /// guard is belt-and-suspenders; validateMenuItem already gates these.
    @objc func defaultTerminalFontSize(_ sender: Any?) {
        guard Self.agentTerminalIsFocused() else { return }
        AgentSessionController.shared.resetFontSize()
    }

    @objc func biggerTerminalFontSize(_ sender: Any?) {
        guard Self.agentTerminalIsFocused() else { return }
        AgentSessionController.shared.increaseFontSize()
    }

    @objc func smallerTerminalFontSize(_ sender: Any?) {
        guard Self.agentTerminalIsFocused() else { return }
        AgentSessionController.shared.decreaseFontSize()
    }

    /// Whether the agent terminal currently holds first responder. Collapses
    /// Galaxy's `focusedTerminalPane()` (which walks the responder chain to a
    /// TerminalHostView across multiple panes) to a single-pane check: walk
    /// up from the first responder looking for the one AgentTerminalHostView.
    /// Returns false when focus is elsewhere (Settings window, no key window)
    /// so ⌘= / ⌘- / ⌘0 don't zoom the terminal from a text field.
    static func agentTerminalIsFocused() -> Bool {
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder as? NSView
        else { return false }
        var view: NSView? = responder
        while let v = view {
            if v is AgentTerminalHostView { return true }
            view = v.superview
        }
        return false
    }

    // MARK: - Agent menu actions

    /// Agent ▸ Scrollback. Posts the notification the agent terminal host
    /// observes to open the scrollback overlay. Mirrors Galaxy's
    /// MenuActions.enterScrollback.
    @objc func enterScrollback(_ sender: Any?) {
        NotificationCenter.default.post(name: .enterScrollback, object: nil)
    }

    /// Agent ▸ Clear / Compact session. Each trims the terminal scrollback
    /// then sends the slash command to the single embedded session, mirroring
    /// Galaxy's clear/compact (minus the /handoff auto-chain — that is Galaxy
    /// multi-session machinery).
    @objc func clearSession(_ sender: Any?) {
        AgentSessionController.shared.clearSession()
    }

    @objc func compactSession(_ sender: Any?) {
        AgentSessionController.shared.compactSession()
    }

    /// Agent ▸ Trim Buffer / Reflow Buffer. Route to the controller like the
    /// font actions; the focus guard is belt-and-suspenders (validateMenuItem
    /// already gates these on the agent terminal holding focus).
    @objc func trimBuffer(_ sender: Any?) {
        guard Self.agentTerminalIsFocused() else { return }
        AgentSessionController.shared.trimBuffer()
    }

    @objc func reflowBuffer(_ sender: Any?) {
        guard Self.agentTerminalIsFocused() else { return }
        AgentSessionController.shared.reflowBuffer()
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showPreferences = Notification.Name("showPreferences")
    static let enterScrollback = Notification.Name("enterScrollback")
}

// MARK: - Menu validation

/// Dynamic enable/disable for the View ▸ font-size shortcuts. AppKit calls
/// validateMenuItem both on visual menu open and on key-equivalent
/// dispatch, so the keyboard shortcut and the visible menu state stay in
/// lockstep without a reactive rebuild. Mirrors Galaxy's MainMenu
/// validateMenuItem (terminal-font cases only). Every other MenuActions
/// item defers to its build-time isEnabled.
extension MenuActions: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controller = AgentSessionController.shared
        switch menuItem.action {
        case #selector(previousView(_:)), #selector(nextView(_:)):
            return MainTab.allCases.count > 1
        case #selector(defaultTerminalFontSize(_:)):
            return Self.agentTerminalIsFocused()
        case #selector(biggerTerminalFontSize(_:)):
            return Self.agentTerminalIsFocused()
                && controller.canIncreaseFontSize
        case #selector(smallerTerminalFontSize(_:)):
            return Self.agentTerminalIsFocused()
                && controller.canDecreaseFontSize
        case #selector(enterScrollback(_:)):
            return controller.state == .running
        case #selector(clearSession(_:)),
             #selector(compactSession(_:)):
            return controller.state == .running
        case #selector(trimBuffer(_:)),
             #selector(reflowBuffer(_:)):
            return Self.agentTerminalIsFocused()
        default:
            return menuItem.isEnabled
        }
    }
}
