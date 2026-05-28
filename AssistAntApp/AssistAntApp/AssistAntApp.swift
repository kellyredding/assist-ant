import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var socket: SocketListener!
    private var events: EventCoordinator!
    private var mainMenu: MainMenu!
    private var mainWindow: MainWindowController?
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Regular dock app from launch: icon visible, Cmd-Tab lists us,
        // main window opens automatically in applicationDidFinishLaunching.
        // The status item is an additional affordance, not the primary
        // entry point.
        NSApp.setActivationPolicy(.regular)

        // Install the menu bar (the strip at the top of the screen) before
        // the app finishes launching so system menu wires are in place
        // when AppKit starts honoring key equivalents.
        mainMenu = MainMenu()
        mainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AssistAntPaths.ensureDirectories()

        // Touch SettingsManager.shared so it loads prefs from disk before
        // any view asks for them. Lazy-init would work too, but warming
        // here keeps first-Settings-open fast.
        _ = SettingsManager.shared

        // Touch ClockService.shared so its minute-aligned ticker starts
        // immediately. ClockView observers see the first tick within a
        // frame of the main window opening.
        _ = ClockService.shared

        // Touch AnnouncementService.shared so it subscribes to ClockService
        // from the moment the app is up — otherwise it would only start
        // observing on first access (e.g., when the settings UI is opened),
        // and any scheduled chime in the meantime would be missed.
        // Start mic-activity monitoring before AnnouncementService so the
        // service's subscription sees a settled initial state. Drives the
        // "mute while microphone in use" behavior.
        MicActivityService.shared.start()

        _ = AnnouncementService.shared

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

        menuBar = MenuBarController(
            onOpenMainWindow: { [weak self] in self?.openMainWindow() },
            onOpenSettings: { PreferencesWindowController.showPreferences() },
            onQuit: { NSApp.terminate(nil) }
        )

        // MenuActions posts named notifications from main-menu items.
        // Observe the ones we care about and dispatch.
        observeMenuNotifications()

        // Auto-open the main window on launch. WindowStatePersistence
        // restores the previous frame/screen if one was saved.
        openMainWindow()

        NSLog("AssistAnt: ready (socket=\(AssistAntPaths.socketPath.path))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronously flush any pending window-state write so a quit
        // mid-drag still records the final frame.
        WindowStatePersistence.shared.flushSync()

        socket?.stop()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    /// Keep the app running when the user closes the main window. Dock
    /// icon stays visible; main window can be reopened from the menu bar
    /// item, the status item, or by clicking the dock icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Reopen the main window when the user clicks the dock icon and no
    /// windows are currently visible.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
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
            mainWindow = MainWindowController()
        }
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Event handling

    private func handleEvent(_ envelope: EventEnvelope) {
        // Skeleton: just log. Future services hook in here.
        let message = envelope.detailValue("message", as: String.self) ?? "<no message>"
        NSLog("AssistAnt: received event '\(envelope.event)' message=\(message)")
    }
}
