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
        // Enable click-through: clicking into an inactive AssistAnt window
        // activates it AND delivers the click to the control in one action,
        // instead of requiring a second click. SwiftUI's internal NSView
        // subclasses return false from acceptsFirstMouse(for:) and can't be
        // subclassed, so swizzle the base NSView method. Mirrors Galaxy.
        NSView.enableClickThrough()

        AssistAntPaths.ensureDirectories()

        // Warm the items database so its migrations run and the file is ready
        // before any view queries it. Machine-local; the consistent backup
        // snapshot rides Syncthing via ItemBackupCoordinator (debounced on
        // change + flushed on quit).
        _ = ItemsDatabase.shared

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

        // Warm the audio coordinator so its mic observer is live before
        // any announcement can fire — it owns cancel-on-mic-engage for
        // all audible output.
        _ = AudioAnnouncementCoordinator.shared

        _ = AnnouncementService.shared

        // Warm the calendar announcer so it subscribes to the clock and the
        // active-calendar feed from launch — otherwise a near-term event
        // could pass its lead time before the service is first touched.
        _ = CalendarAnnouncementService.shared

        // Warm DeskService so its launch fixup runs, its clock/mic
        // observers wire up, and a nudge pending on launch begins its
        // audible repeat. The visible countdown/nudge is derived live by
        // the views.
        DeskService.shared.start()

        // Auto-away: flip to "away from desk" (which mutes announcements)
        // when the screen locks or the machine sleeps. One-way — returning
        // to the desk is manual.
        AwayTriggerService.shared.start()

        // Warm + start the embedded agent session. App-level so it survives
        // the main window closing. Resumes the persisted session id, or
        // starts fresh (and runs the persona's daily briefing once) when no
        // id exists on this machine.
        AgentSessionController.shared.startOnLaunch()

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
        // Terminate the embedded agent's child process tree at a controlled
        // point so it doesn't outlive the app or leave a lingering process
        // that blocks a clean relaunch.
        AgentSessionController.shared.stop()

        // Synchronously flush any pending window-state write so a quit
        // mid-drag still records the final frame.
        WindowStatePersistence.shared.flushSync()

        // Synchronously snapshot the items database to its Sync-backed backup
        // so the final state is captured even if the debounce hadn't fired.
        ItemBackupCoordinator.shared.flushSync()

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

        // Surfaced by DeskService when a desk nudge first becomes audible,
        // so the actionable banner is in front when it speaks.
        let raiseObserver = NotificationCenter.default.addObserver(
            forName: .raiseMainWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openMainWindow()
        }
        notificationObservers.append(raiseObserver)
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

    private func handleEvent(_ e: EventEnvelope) {
        switch e.event {
        case "calendar_item.upsert": upsertCalendarItem(e)
        case "calendar_item.prune": pruneCalendarItems(e)
        case "ping":
            let message = e.detailValue("message", as: String.self) ?? "<no message>"
            NSLog("AssistAnt: ping — \(message)")
        default:
            NSLog("AssistAnt: unhandled event '\(e.event)'")
        }
    }

    /// Upsert a calendar item from a `calendar_item.upsert` envelope. Every
    /// domain field comes from the CLI; the app supplies the internal id, the
    /// workspace scope, and the sync-managed fields. Identity is
    /// `(workspace, source, external_id)`.
    private func upsertCalendarItem(_ e: EventEnvelope) {
        let iso = ISO8601DateFormatter()
        guard let externalID = e.detailValue("external_id", as: String.self),
              let source = e.detailValue("source", as: String.self),
              let title = e.detailValue("title", as: String.self),
              let startStr = e.detailValue("start_at", as: String.self),
              let startAt = iso.date(from: startStr)
        else {
            NSLog("AssistAnt: calendar_item.upsert missing required fields")
            return
        }
        let workspaceID: String
        do { workspaceID = try WorkspaceStore.shared.current().id }
        catch {
            NSLog("AssistAnt: calendar_item.upsert — cannot resolve workspace: \(error)")
            return
        }
        let item = Item(
            id: UUIDv7.generate(),
            workspaceID: workspaceID,
            type: ItemType.calendar.rawValue,
            title: title,
            body: e.detailValue("body", as: String.self),
            source: source,
            externalID: externalID,
            typeData: .calendar(CalendarData(
                startAt: startAt,
                endAt: e.detailValue("end_at", as: String.self).flatMap(iso.date(from:)),
                allDay: false,
                timeZoneID: e.detailValue("time_zone", as: String.self))),
            iceboxedAt: nil,
            deletedAt: nil,
            scheduledOn: e.detailValue("scheduled_on", as: String.self)
                .flatMap(CivilDate.init(iso:)),
            createdAt: Date(),
            updatedAt: Date(),
            serverUpdatedAt: nil,
            pending: true)
        do { try GRDBItemStore.shared.upsert(item) }
        catch { NSLog("AssistAnt: calendar_item.upsert failed: \(error)") }
    }

    /// Window-scoped reconcile from a `calendar_item.prune` envelope: soft-delete
    /// items in [from, to] for the source that aren't in the keep set.
    private func pruneCalendarItems(_ e: EventEnvelope) {
        guard let source = e.detailValue("source", as: String.self),
              let fromStr = e.detailValue("from", as: String.self),
              let toStr = e.detailValue("to", as: String.self),
              let from = CivilDate(iso: fromStr),
              let to = CivilDate(iso: toStr)
        else {
            NSLog("AssistAnt: calendar_item.prune missing source/from/to")
            return
        }
        let workspaceID: String
        do { workspaceID = try WorkspaceStore.shared.current().id }
        catch {
            NSLog("AssistAnt: calendar_item.prune — cannot resolve workspace: \(error)")
            return
        }
        let keep = Set(e.detailValue("keep", as: [String].self) ?? [])
        let allowEmptyKeep = e.detailValue("allow_empty", as: Bool.self) ?? false
        do {
            try GRDBItemStore.shared.pruneMissing(
                workspaceID: workspaceID, source: source, from: from, to: to,
                keep: keep, allowEmptyKeep: allowEmptyKeep)
        } catch ItemStoreError.emptyKeepPruneRefused {
            NSLog("AssistAnt: calendar_item.prune refused — empty keep set without allow_empty; nothing retired")
        } catch {
            NSLog("AssistAnt: calendar_item.prune failed: \(error)")
        }
    }
}

extension Notification.Name {
    /// Posted by `DeskService` when a desk nudge first becomes audible, so
    /// the AppDelegate can bring the main window forward.
    static let raiseMainWindow = Notification.Name("raiseMainWindow")
}

// MARK: - Click-through swizzle

extension NSView {
    /// Swizzle `acceptsFirstMouse(for:)` on NSView to return true globally,
    /// enabling click-through for every view — including SwiftUI's internal
    /// view classes that can't be subclassed. Called once at app launch.
    /// Mirrors Galaxy's enableClickThrough.
    static func enableClickThrough() {
        let original = class_getInstanceMethod(
            NSView.self, #selector(acceptsFirstMouse(for:))
        )!
        let replacement = class_getInstanceMethod(
            NSView.self, #selector(assistAnt_acceptsFirstMouse(for:))
        )!
        method_exchangeImplementations(original, replacement)
    }

    @objc private func assistAnt_acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        return true
    }
}
