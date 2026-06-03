import AppKit

/// Owns the NSStatusItem. The button image is the menubar template
/// silhouette from the asset catalog; macOS recolors it for light/dark
/// mode automatically. The menu has Open / Settings / Mute /
/// announcements / Quit. The Mute item is hidden when master Enable
/// is off, and its title + submenu reflect mute state at show time
/// (rebuilt via NSMenuDelegate.menuNeedsUpdate). Keyboard shortcuts
/// on the main menu (⌘, for Settings, ⌘Q for Quit) work app-wide
/// when AssistAnt is focused; status-menu keyEquivalents only fire
/// while the status menu is open, so they're omitted here.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    /// Held so `menuNeedsUpdate(_:)` can update title / hidden /
    /// submenu without rebuilding the entire menu on every show.
    private var muteItem: NSMenuItem?

    /// Standing-desk switch nudge item. Hidden except while a desk
    /// nudge is pending; its title ("Time to Stand" / "Time to Sit")
    /// and "I Switched" submenu are set by `menuNeedsUpdate(_:)`.
    private var deskItem: NSMenuItem?

    init(
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        configure()
    }

    private func configure() {
        if let button = statusItem.button {
            if let image = NSImage(named: "MenubarIcon") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback if the asset is missing for any reason
                // (asset catalog not compiled in, name mismatch).
                button.title = "AssistAnt"
            }
            button.toolTip = "AssistAnt"
        }

        let menu = NSMenu()
        menu.delegate = self

        let openItem = NSMenuItem(
            title: "Open AssistAnt…",
            action: #selector(handleOpen),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Mute item — title, hidden state, and submenu are all set
        // by menuNeedsUpdate(_:) just before the menu shows. Action
        // is nil because the item has a submenu (AppKit shows the
        // submenu on hover; submenu items have their own actions).
        let muteItem = NSMenuItem(
            title: "Mute announcements",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(muteItem)
        self.muteItem = muteItem

        // Desk switch nudge — title/hidden/submenu set in
        // menuNeedsUpdate(_:). Action nil because it carries a submenu.
        let deskItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(deskItem)
        self.deskItem = deskItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit AssistAnt",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Refresh the mute item just before the menu displays. Avoids
    /// needing a live observer on settings + clock for the menu bar
    /// menu — the menu state is only relevant when the menu is open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = muteItem else { return }
        let now = Date()
        let appSettings = SettingsManager.shared.settings
        let state = appSettings.iconState(
            at: now,
            micInUse: MicActivityService.shared.isMicInUse
        )

        switch state {
        case .disabled:
            item.isHidden = true

        case .scheduled, .active:
            item.isHidden = false
            item.title = "Mute announcements"
            item.submenu = buildMuteSubmenu()

        case .mutedByTimer:
            item.isHidden = false
            let display = MuteController.currentMuteEndDisplay(
                format: appSettings.timeFormat,
                now: now
            )
            item.title = display.map { "Muted until \($0)" }
                ?? "Announcements muted"
            item.submenu = buildUnmuteSubmenu()

        case .mutedByMic:
            // Mic-mute clears itself when the mic frees — nothing to
            // act on, so the item is informational with no submenu.
            item.isHidden = false
            item.title = "Muted while microphone in use"
            item.submenu = nil

        case .mutedByAway:
            // Cleared by returning to the desk (the away banner), not
            // from this menu — informational, no submenu.
            item.isHidden = false
            item.title = "Muted while away from desk"
            item.submenu = nil
        }

        updateDeskItem(at: now)
    }

    /// Refresh the desk nudge item. Visible only while a switch is
    /// pending; the title names the position to move *to* ("Time to
    /// Stand" / "Time to Sit") and the submenu acknowledges. Counting
    /// and inactive phases hide it — the desk timer surfaces in the
    /// menu bar only when it needs the user to act.
    private func updateDeskItem(at now: Date) {
        guard let deskItem = deskItem else { return }
        let phase = SettingsManager.shared.settings.desk.timerPhase(at: now)
        switch phase {
        case .nudge(let from):
            deskItem.isHidden = false
            deskItem.title = "Time to \(from.opposite.verb.capitalized)"
            deskItem.submenu = buildDeskSwitchSubmenu()
        case .counting, .inactive, .away:
            deskItem.isHidden = true
            deskItem.submenu = nil
        }
    }

    private func buildMuteSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.addItem(
            NSMenuItem.sectionHeader(title: "Mute announcements for")
        )
        for duration in MuteDuration.allCases {
            let item = NSMenuItem(
                title: duration.displayName,
                action: #selector(handleMute(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration
            sub.addItem(item)
        }
        return sub
    }

    private func buildUnmuteSubmenu() -> NSMenu {
        let sub = NSMenu()
        // No section header here — the parent menu item already reads
        // "Muted until X", so repeating it as a submenu header is
        // redundant. The submenu is just the unmute action. (The
        // in-window AnnounceStatusButton keeps its header because its
        // parent affordance is an icon with no visible title.)
        let unmuteItem = NSMenuItem(
            title: "Unmute now",
            action: #selector(handleUnmute),
            keyEquivalent: ""
        )
        unmuteItem.target = self
        sub.addItem(unmuteItem)
        return sub
    }

    @objc private func handleOpen() { onOpenMainWindow() }
    @objc private func handleSettings() { onOpenSettings() }
    @objc private func handleQuit() { onQuit() }

    @objc private func handleMute(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? MuteDuration
        else { return }
        MuteController.mute(for: duration)
    }

    @objc private func handleUnmute() {
        MuteController.unmute()
    }

    private func buildDeskSwitchSubmenu() -> NSMenu {
        let sub = NSMenu()
        let item = NSMenuItem(
            title: "I Switched",
            action: #selector(handleDeskSwitch),
            keyEquivalent: ""
        )
        item.target = self
        sub.addItem(item)
        return sub
    }

    @objc private func handleDeskSwitch() {
        DeskService.shared.acknowledgeSwitch()
    }
}
