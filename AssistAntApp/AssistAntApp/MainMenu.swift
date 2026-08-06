import AppKit
import Combine
import Galactic

/// Builds and manages the application's menu bar (the menu strip at the top
/// of the screen). Programmatic NSMenu construction, mirroring Galaxy's pattern
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/MainMenu.swift).
///
/// Routes menu item actions through MenuActions.shared, which posts named
/// NSNotifications. AppDelegate observes those notifications and dispatches
/// to the right subsystem. The indirection lets new menu items slot in
/// without AppDelegate having to know about every menu wiring.
///
/// A binding added here also needs a row in `KeystrokeCatalog`, or it will not
/// appear in the ⌘/ cheat sheet — and nothing fails to say so, because the
/// catalog restates these facts rather than deriving them.
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

        // File menu — the home for ⌘W, plus the way back to a closed window.
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

        // Terminal menu — terminal font zoom plus the session-acting Clear /
        // Compact commands sent to the embedded session's PTY. AssistAnt's
        // analog of Galaxy's Sessions menu, named for the tab it acts on
        // (singular here, since exactly one session is embedded). Font items
        // gate on the terminal holding focus; Clear / Compact gate on the
        // session running (both via validateMenuItem).
        let terminalMenu = NSMenu(title: "Terminal")
        let terminalMenuItem = NSMenuItem(
            title: "Terminal", action: nil, keyEquivalent: ""
        )
        terminalMenuItem.submenu = terminalMenu
        mainMenu.addItem(terminalMenuItem)
        buildTerminalMenu(terminalMenu)

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

        // Help menu — home for the ⌘/ keystroke cheat sheet, which is where
        // people look for one. AppKit attaches its own search field to any
        // menu titled exactly "Help"; that is standard behaviour, not a stray
        // control of ours.
        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(
            title: "Help", action: nil, keyEquivalent: ""
        )
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        buildHelpMenu(helpMenu)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Help menu

    /// Keyboard Shortcuts (⌘/) opens the in-window cheat sheet. A menu item
    /// rather than another local key monitor: the app already runs several of
    /// those and they have to reason about one another, whereas a menu item
    /// gets dispatch, validation, and menu-bar discoverability for free.
    private func buildHelpMenu(_ menu: NSMenu) {
        let shortcutsItem = NSMenuItem(
            title: "Keyboard Shortcuts",
            action: #selector(MenuActions.showKeystrokeSheet(_:)),
            keyEquivalent: "/"
        )
        shortcutsItem.target = MenuActions.shared
        menu.addItem(shortcutsItem)
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
        // Main Window — the keyboard route back once the window is closed.
        // A windowless regular app still shows its menu bar when it comes
        // forward, so ⌘-Tab and then this item reopens without the mouse;
        // clicking the dock icon does the same thing.
        let showItem = NSMenuItem(
            title: "Main Window",
            action: #selector(MenuActions.showMainWindow(_:)),
            keyEquivalent: ""
        )
        showItem.target = MenuActions.shared
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Close Window (⌘W) — first responder routes this to the key window
        // via performClose:, which the window's red close button also uses.
        // Both therefore pass through MainWindowController.windowShouldClose,
        // which confirms while the agent session is running.
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

        menu.addItem(.separator())

        // Find (⌘F) — searches the scrollback, opening one at the current
        // viewport if none is up. The first item in this menu with an
        // explicit target; the rest ride the responder chain.
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(MenuActions.find(_:)),
            keyEquivalent: "f"
        )
        findItem.target = MenuActions.shared
        menu.addItem(findItem)
    }

    // MARK: - View menu

    /// Previous/Next view switch the main window's right-pane tab. Each has a
    /// letter binding (⇧⌘H/⇧⌘L) plus a hidden arrow alternate (⇧⌘←/⇧⌘→),
    /// matching Galaxy. Shifted because a view is one level out from the
    /// content inside it: unshifted belongs to the innermost thing you are
    /// in. Enable state is gated dynamically by validateMenuItem.
    private func buildViewMenu(_ menu: NSMenu) {
        let prev = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: "h"
        )
        prev.target = MenuActions.shared
        prev.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prev)

        let prevArrow = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevArrow.target = MenuActions.shared
        prevArrow.keyEquivalentModifierMask = [.command, .shift]
        prevArrow.isAlternate = true
        menu.addItem(prevArrow)

        let next = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: "l"
        )
        next.target = MenuActions.shared
        next.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(next)

        let nextArrow = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextArrow.target = MenuActions.shared
        nextArrow.keyEquivalentModifierMask = [.command, .shift]
        nextArrow.isAlternate = true
        menu.addItem(nextArrow)
    }

    // MARK: - Agent menu

    private func buildTerminalMenu(_ menu: NSMenu) {
        // Terminal font size on top. Enable state is computed dynamically
        // by validateMenuItem — gated on the agent terminal holding first
        // responder. No explicit modifier mask: the items take AppKit's
        // default (.command), matching Galaxy.
        //
        // The group sits under a disabled heading with its members indented,
        // as Galaxy's does. Two of the three can only say "Bigger" and
        // "Smaller" — there is no third word for what they resize — so the
        // surface has to be named somewhere above them, and naming it in the
        // heading lets the reset item say only what it does rather than
        // repeating a menu already titled Terminal. The heading takes no
        // action, so AppKit disables it whatever validation computes for the
        // items around it.
        //
        // Only this group is headed. The pane, buffer and session groups below
        // are separated by dividers alone, because each of their items already
        // names its own object — "Trim Buffer" needs no heading the way
        // "Bigger" does.
        let fontHeader = NSMenuItem(
            title: "Terminal Font Size", action: nil, keyEquivalent: ""
        )
        fontHeader.isEnabled = false
        menu.addItem(fontHeader)

        let defaultItem = NSMenuItem(
            title: "Default",
            action: #selector(MenuActions.defaultTerminalFontSize(_:)),
            keyEquivalent: "0"
        )
        defaultItem.target = MenuActions.shared
        defaultItem.indentationLevel = 1
        menu.addItem(defaultItem)

        let biggerItem = NSMenuItem(
            title: "Bigger",
            action: #selector(MenuActions.biggerTerminalFontSize(_:)),
            keyEquivalent: "="
        )
        biggerItem.target = MenuActions.shared
        biggerItem.indentationLevel = 1
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(
            title: "Smaller",
            action: #selector(MenuActions.smallerTerminalFontSize(_:)),
            keyEquivalent: "-"
        )
        smallerItem.target = MenuActions.shared
        smallerItem.indentationLevel = 1
        menu.addItem(smallerItem)

        menu.addItem(.separator())

        // Pane commands, directional rather than mnemonic: the panes are
        // stacked, so K is up to the session and J is down to the shell.
        // ⇧⌘O opens a login shell below, or focuses one already open.
        // Bindings match Galaxy's Sessions menu.
        //
        // ⌘T and ⇧⌘T carried the first two and are deliberately left
        // unbound — a file picker wants ⌘T and every editor agrees.
        //
        // ⌘W is not a menu item — the File menu keeps it as Close Window,
        // and a local event monitor consumes it only while a shell holds
        // focus.
        let vertical = MenuActions.verticalNavDescriptor()
        let focusSessionItem = NSMenuItem(
            title: vertical.previous,
            action: #selector(MenuActions.verticalNavPrevious(_:)),
            keyEquivalent: "k"
        )
        focusSessionItem.target = MenuActions.shared
        menu.addItem(focusSessionItem)

        let focusSessionArrowItem = NSMenuItem(
            title: vertical.previous,
            action: #selector(MenuActions.verticalNavPrevious(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        focusSessionArrowItem.target = MenuActions.shared
        focusSessionArrowItem.keyEquivalentModifierMask = .command
        focusSessionArrowItem.isAlternate = true
        menu.addItem(focusSessionArrowItem)

        let focusShellItem = NSMenuItem(
            title: vertical.next,
            action: #selector(MenuActions.verticalNavNext(_:)),
            keyEquivalent: "j"
        )
        focusShellItem.target = MenuActions.shared
        menu.addItem(focusShellItem)

        let focusShellArrowItem = NSMenuItem(
            title: vertical.next,
            action: #selector(MenuActions.verticalNavNext(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        focusShellArrowItem.target = MenuActions.shared
        focusShellArrowItem.keyEquivalentModifierMask = .command
        focusShellArrowItem.isAlternate = true
        menu.addItem(focusShellArrowItem)

        let openShellItem = NSMenuItem(
            title: "Open Shell Pane",
            action: #selector(MenuActions.openShellPane(_:)),
            keyEquivalent: "o"
        )
        openShellItem.target = MenuActions.shared
        menu.addItem(openShellItem)

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

    @objc func showMainWindow(_ sender: Any?) {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    @objc func showPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .showPreferences, object: nil)
    }

    /// Help ▸ Keyboard Shortcuts (⌘/). Toggles, so the same keystroke that
    /// summons the sheet puts it away.
    ///
    /// `assumeIsolated` rather than a hop: AppKit dispatches menu actions on
    /// the main thread, and hopping would let the sheet's snapshot be taken a
    /// runloop turn later than the keystroke that asked for it.
    ///
    /// More load-bearing now, not less. The snapshot is taken inside the
    /// sections provider that `toggle()` invokes — see `KeystrokeSheet` — so a
    /// hop would move the reading of focus and selection, not just the
    /// presentation.
    @objc func showKeystrokeSheet(_ sender: Any?) {
        MainActor.assumeIsolated { CheatSheetPresenter.shared.toggle() }
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

    /// Terminal ▸ Terminal Font Size ▸ Default / Bigger / Smaller. Each acts on
    /// the pane holding focus, so zooming a shell strip down leaves the agent
    /// readable above it. `validateMenuItem` already gates these; the
    /// optional chain is what makes "no pane focused" a no-op.
    @objc func defaultTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.resetFontSize()
    }

    @objc func biggerTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.increaseFontSize()
    }

    @objc func smallerTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.decreaseFontSize()
    }

    /// The pane holding first responder, or nil when focus is somewhere else
    /// entirely (a text field, the settings window, no key window) — which is
    /// what keeps ⌘= / ⌘- / ⌘0 from zooming a terminal the user isn't in.
    ///
    /// Walks up from the first responder rather than asking any pane, so it
    /// stays correct however many panes exist and whatever is nested inside
    /// them.
    static func focusedTerminalPane() -> TerminalPane? {
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder as? NSView
        else { return nil }
        var view: NSView? = responder
        while let v = view {
            if let host = v as? TerminalHostView { return host.pane }
            view = v.superview
        }
        return nil
    }

    /// Whether any terminal pane holds first responder.
    ///
    /// Deliberately the strict question, and deliberately not
    /// `targetTerminalPane()`: this feeds the keystroke sheet's snapshot, which
    /// reports where focus *is* rather than which pane a command would reach.
    static func agentTerminalIsFocused() -> Bool {
        focusedTerminalPane() != nil
    }

    /// The pane a pane-directed command should act on.
    ///
    /// Prefers the first responder, which is unambiguous while the user is
    /// typing in a terminal. Falls back to the pane-focus memory when that walk
    /// finds nothing — which is not an edge case but two ordinary situations:
    /// the find bar takes key in a panel of its own, so `NSApp.keyWindow` is not
    /// the main window at all; and leaving a pane ends in
    /// `makeFirstResponder(nil)`, which leaves the window itself holding it, and
    /// a window is not an `NSView`. In both the user is looking straight at the
    /// terminal they were last in, and every pane-directed keystroke was dead
    /// until they clicked back into it.
    ///
    /// Gated on the Terminal view, because the fallback answers "which pane was
    /// last focused" and would otherwise answer it just as readily while the
    /// user is somewhere else entirely — zooming a terminal that is not on
    /// screen.
    static func targetTerminalPane() -> TerminalPane? {
        if let focused = focusedTerminalPane() { return focused }
        guard MainTabNavigator.shared.selectedTab == .terminal
        else { return nil }
        return TerminalPanes.pane(
            kind: TerminalPanes.shared.lastFocusedPaneKind
        )
    }

    /// Whether the key window's first responder is an *editable* text view —
    /// e.g. the actionable reader's title field editor or its body editor.
    /// Read-only text (the rendered body: selectable but not editable) returns
    /// false, so View ▸ Previous/Next view stays enabled while merely viewing.
    /// Used to surrender ⌘←/→ and ⌘H/⌘L to the focused editor so its native
    /// line navigation — including ⌘⇧←/→ selection and ⌥-word motion — works.
    static func editableTextIsFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView
        else { return false }
        return responder.isEditable
    }

    // MARK: - Agent menu actions

    /// Agent ▸ Scrollback. Posts the notification the agent terminal host
    /// observes to open the scrollback overlay. Mirrors Galaxy's
    /// MenuActions.enterScrollback.
    @objc func enterScrollback(_ sender: Any?) {
        NotificationCenter.default.post(name: .enterScrollback, object: nil)
    }

    /// Edit ▸ Find… (⌘F). Posted rather than called directly, for the same
    /// reason Scrollback is: the menu has no handle on whichever terminal
    /// host should answer.
    @objc func find(_ sender: Any?) {
        NotificationCenter.default.post(name: .activateFind, object: nil)
    }

    /// Terminal ▸ Focus Session Pane (⌘T).
    /// ⇧⌘K — the previous thing on this surface. Today that is always the
    /// session pane; the Files tab will make it the tab row above.
    @objc func verticalNavPrevious(_ sender: Any?) {
        TerminalTabCommands.shared.focusSession.send(nil)
    }

    /// Titles for the ⇧⌘K / ⇧⌘J pair.
    ///
    /// One pair of menu items rather than one per meaning, and a
    /// descriptor rather than literal titles, even though there is only
    /// one meaning today. Two items sharing a key equivalent do not both
    /// stay bound — AppKit unbinds one silently — so the Files tab has to
    /// add a branch here rather than a second claimant. Building the seam
    /// now is the difference between a branch and a bug.
    static func verticalNavDescriptor() -> (
        previous: String, next: String
    ) {
        ("Focus Session Pane", "Focus Shell Pane")
    }

    /// Terminal ▸ Focus Shell Pane (⇧⌘J / ⇧⌘↓). Declines when no shell
    /// is open — opening one is `openShellPane`.
    /// ⇧⌘J — the next thing on this surface. Declines to open a shell that
    /// is not there; that is `openShellPane`.
    @objc func verticalNavNext(_ sender: Any?) {
        TerminalTabCommands.shared.focusShell.send(nil)
    }

    /// Terminal ▸ Open Shell Pane (⇧⌘O). Opens the split, or focuses the
    /// shell when one is already open.
    @objc func openShellPane(_ sender: Any?) {
        TerminalTabCommands.shared.openShell.send(nil)
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

    /// Terminal ▸ Trim Buffer / Reflow Buffer. Like the font actions, these
    /// act on the focused pane — trimming a shell's runaway output should not
    /// clear the agent's history, and vice versa.
    @objc func trimBuffer(_ sender: Any?) {
        Self.targetTerminalPane()?.trimBuffer()
    }

    @objc func reflowBuffer(_ sender: Any?) {
        Self.targetTerminalPane()?.reflowBuffer()
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showPreferences = Notification.Name("showPreferences")
    static let enterScrollback = Notification.Name("enterScrollback")
    static let activateFind = Notification.Name("activateFind")
}

extension MenuActions {
    /// The ⌘F notification above, as a terminal host consumes it.
    ///
    /// A host is told that the user asked to find; how the menu said so is
    /// this app's business, and a broadcast is how it says so here because the
    /// menu has no handle on whichever host should answer. Mapping it where the
    /// notification is declared keeps both halves of that decision together.
    static var findActivations: FindActivations {
        NotificationCenter.default
            .publisher(for: .activateFind)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// The ⌘S notification above, as a terminal host consumes it. Same shape
    /// and same reasoning as the find gesture beside it.
    static var scrollbackActivations: ScrollbackActivations {
        NotificationCenter.default
            .publisher(for: .enterScrollback)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
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
            // Surrender ⌘←/→ and ⌘H/⌘L to a focused text editor so its native
            // line navigation (incl. ⌘⇧←/→ selection) wins over tab switching.
            return MainTab.allCases.count > 1 && !Self.editableTextIsFocused()
        case #selector(defaultTerminalFontSize(_:)):
            return Self.targetTerminalPane() != nil
        case #selector(biggerTerminalFontSize(_:)):
            // Read the ceiling from the focused pane, not the session: the
            // shell keeps its own size and may still have room when the agent
            // does not.
            return Self.targetTerminalPane()?.canIncreaseFontSize ?? false
        case #selector(smallerTerminalFontSize(_:)):
            return Self.targetTerminalPane()?.canDecreaseFontSize ?? false
        case #selector(enterScrollback(_:)),
             #selector(find(_:)):
            // Find is gated exactly like Scrollback, since it opens one when
            // none is up. Deliberately not routed through
            // focusedTerminalPane(), which resolves via NSApp.keyWindow and
            // returns nil once the find panel takes key — that would disable
            // Find precisely when the user presses ⌘F a second time.
            return controller.state == .running
        case #selector(clearSession(_:)),
             #selector(compactSession(_:)):
            return controller.state == .running
        case #selector(trimBuffer(_:)),
             #selector(reflowBuffer(_:)):
            // Matches what the actions now reach for. Gated on a pane being
            // nameable rather than focused, for the reason given on
            // `targetTerminalPane` — asking for focus here disabled the item
            // while its action would have worked, and a disabled item does not
            // claim its key equivalent.
            return Self.targetTerminalPane() != nil
        case #selector(verticalNavPrevious(_:)),
             #selector(verticalNavNext(_:)),
             #selector(openShellPane(_:)):
            // Gate on the tab, not on focus: both commands are about moving
            // focus into the Terminal tab's panes, so they stay live while
            // the tab is showing but something else holds first responder.
            // Without the gate, the split stays mounted behind another tab
            // and would take a shell — or focus — out of sight.
            return MainTabNavigator.shared.selectedTab == .terminal
        default:
            return menuItem.isEnabled
        }
    }
}
