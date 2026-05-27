import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var socket: SocketListener!
    private var events: EventCoordinator!
    private var policy: ActivationPolicyManager!
    private var mainMenu: MainMenu!
    private var mainWindow: MainWindowController?
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start as accessory so no dock icon shows on launch.
        // ActivationPolicyManager flips to .regular when a window
        // opens, back to .accessory when the last closes.
        NSApp.setActivationPolicy(.accessory)

        // Install the menu bar (the strip at the top of the screen)
        // before the app finishes launching so the system menu wires
        // are in place when AppKit starts honoring key equivalents.
        mainMenu = MainMenu()
        mainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AssistAntPaths.ensureDirectories()

        // Touch SettingsManager.shared so it loads prefs from disk before
        // any view asks for them. Lazy-init would work too, but warming
        // here keeps first-Settings-open fast.
        _ = SettingsManager.shared

        events = EventCoordinator()
        events.onEvent = { [weak self] envelope in
            self?.handleEvent(envelope)
        }

        socket = SocketListener(
            socketPath: AssistAntPaths.socketPath.path,
            lockPath: AssistAntPaths.socketLockPath.path
        )
        socket.onEnvelope = { [weak self] envelope in
            self?.events.route(envelope)
        }
        if !socket.start() {
            // Another AssistAnt is already running. Refuse to bind
            // and exit. Single-instance discipline.
            NSLog("AssistAnt: another instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        policy = ActivationPolicyManager()

        menuBar = MenuBarController(
            onOpenMainWindow: { [weak self] in self?.openMainWindow() },
            onOpenSettings: { PreferencesWindowController.showPreferences() },
            onQuit: { NSApp.terminate(nil) }
        )

        // MenuActions posts named notifications from main-menu items.
        // Observe the ones we care about and dispatch.
        observeMenuNotifications()

        NSLog("AssistAnt: ready (socket=\(AssistAntPaths.socketPath.path))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        socket?.stop()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    // MARK: - Menu notification routing

    private func observeMenuNotifications() {
        let prefsObserver = NotificationCenter.default.addObserver(
            forName: .showPreferences,
            object: nil,
            queue: .main
        ) { _ in
            PreferencesWindowController.showPreferences()
        }
        notificationObservers.append(prefsObserver)
    }

    // MARK: - Window lifecycle

    private func openMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowController(onClose: { [weak self] in
                self?.mainWindow = nil
                self?.policy.windowClosed()
            })
        }
        policy.windowOpened()
        mainWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Event handling

    private func handleEvent(_ envelope: EventEnvelope) {
        // Skeleton: just log. Future services hook in here.
        let message = envelope.detailValue("message", as: String.self) ?? "<no message>"
        NSLog("AssistAnt: received event '\(envelope.event)' message=\(message)")
    }
}
