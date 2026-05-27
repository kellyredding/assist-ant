import AppKit

/// Owns the NSStatusItem. Skeleton menu has two items:
/// "Open AssistAnt..." and "Quit". The button title is the
/// placeholder "AssistAnt" — phase 1 replaces it with the live
/// clock.
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onOpenMainWindow: () -> Void
    private let onQuit: () -> Void

    init(
        onOpenMainWindow: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
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
    @objc private func handleQuit() { onQuit() }
}
