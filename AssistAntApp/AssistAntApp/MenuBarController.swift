import AppKit

/// Owns the NSStatusItem. The button image is the menubar template
/// silhouette from the asset catalog; macOS recolors it for light/dark
/// mode automatically. The menu has Open / Settings / Quit. Keyboard
/// shortcuts on the main menu (⌘, for Settings, ⌘Q for Quit) work
/// app-wide when AssistAnt is focused; status-menu keyEquivalents only
/// fire while the status menu is open, so they're omitted here.
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

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

    @objc private func handleOpen() { onOpenMainWindow() }
    @objc private func handleSettings() { onOpenSettings() }
    @objc private func handleQuit() { onQuit() }
}
