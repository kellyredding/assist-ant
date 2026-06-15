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

        // Install/refresh app-owned workspace files (CLAUDE.md + agent skills)
        // before the session starts, so the project memory and skills are
        // always present and match the shipped version (self-heals a missing or
        // hand-edited copy).
        WorkspaceInstaller.installIfNeeded()

        // Install/refresh the SessionStart hook in the workspace BEFORE the
        // agent spawns, so it fires on this launch's resume and the app learns
        // the live session id. The CLI owns the marker-merge (single source of
        // truth); this just triggers it.
        AgentHookInstaller.installIfNeeded()

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

        // Socket + event routing must be live BEFORE the agent spawns: the
        // agent's SessionStart hook publishes `session:ready` to this socket
        // immediately on resume, and we must not miss it.
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
        // Request events (the persona's briefing read) get a reply on the same
        // connection; handled off the main queue since it's a quick store read.
        socket.onRequest = { [weak self] envelope in
            self?.handleRequest(envelope)
        }
        if !socket.start() {
            // Another AssistAnt is already running. Refuse to bind
            // and exit. Single-instance discipline.
            NSLog("AssistAnt: another instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        // Warm + start the embedded agent session. App-level so it survives
        // the main window closing. Resumes the persisted session id, or starts
        // fresh (and runs the persona's daily briefing once) when no id exists
        // on this machine. Started after the socket is listening so the
        // resume's `session:ready` is captured.
        AgentSessionController.shared.startOnLaunch()

        menuBar = MenuBarController(
            onOpenMainWindow: { [weak self] in self?.openMainWindow() },
            onOpenSettings: { PreferencesWindowController.showPreferences() },
            onQuit: { NSApp.terminate(nil) }
        )

        // MenuActions posts named notifications from main-menu items.
        // Observe the ones we care about and dispatch.
        observeMenuNotifications()

        // Quick Capture: register the per-kind global shortcuts that summon the
        // capture popover from any app (Ask defaults to ⌃⌥⌘P; the rest are
        // user-configured in the Capture settings tab). Additive and
        // independent of the main window and the embedded agent.
        CapturePanelController.shared.installCaptureShortcuts()

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

        let openWindowObserver = NotificationCenter.default.addObserver(
            forName: .openMainWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openMainWindow()
        }
        notificationObservers.append(openWindowObserver)
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
        case "calendar_item.sync": syncCalendarItems(e)
        case "actionable_item.sync": syncActionableItems(e)
        case "actionable_item.create": createActionableItem(e)
        case "session:ready":
            guard let id = e.detailValue("session_id", as: String.self) else { break }
            let source = e.detailValue("source", as: String.self) ?? ""
            AgentSessionController.shared.reconcileSession(id: id, source: source)
        case "ping":
            let message = e.detailValue("message", as: String.self) ?? "<no message>"
            NSLog("AssistAnt: ping — \(message)")
        default:
            NSLog("AssistAnt: unhandled event '\(e.event)'")
        }
    }

    /// Answer a request envelope that expects a reply — the persona's startup
    /// briefing read. Runs on the socket listener queue (store reads are
    /// thread-safe), returning the JSON reply bytes, or nil for non-request
    /// events (which fall through to the fire-and-forget `handleEvent` path).
    private func handleRequest(_ e: EventEnvelope) -> Data? {
        switch e.event {
        case "briefing.query":
            return BriefingSnapshot.replyData()
        case "actionable_item.list_names":
            return listNamesReplyData()
        default:
            return nil
        }
    }

    /// Reply to `actionable_item.list_names`: the existing list names as JSON
    /// (`{"lists":[...]}`) for the capture skill to fuzzy/semantic-match a named
    /// list against. Store reads are thread-safe, so this is fine on the
    /// listener queue.
    private func listNamesReplyData() -> Data? {
        let names = (try? GRDBItemStore.shared.knownListNames()) ?? []
        return try? JSONSerialization.data(
            withJSONObject: ["lists": names], options: [.sortedKeys])
    }

    /// Apply a `calendar_item.sync` envelope: read the batch file the CLI
    /// wrote (the qualifying items + the prune window + keep set), upsert all
    /// items and prune the window in one atomic transaction, then delete the
    /// temp file. The app supplies each item's internal id, workspace scope,
    /// and sync-managed fields. Identity is `(workspace, source, external_id)`.
    private func syncCalendarItems(_ e: EventEnvelope) {
        guard let batchPath = e.detailValue("batch_file", as: String.self) else {
            NSLog("AssistAnt: calendar_item.sync missing batch_file")
            return
        }
        // Always clean up the temp batch file, whatever happens below.
        defer { try? FileManager.default.removeItem(atPath: batchPath) }

        guard let data = FileManager.default.contents(atPath: batchPath) else {
            NSLog("AssistAnt: calendar_item.sync — batch file unreadable: \(batchPath)")
            return
        }
        let batch: CalendarSyncBatch
        do {
            batch = try JSONDecoder().decode(CalendarSyncBatch.self, from: data)
        } catch {
            NSLog("AssistAnt: calendar_item.sync — decode failed: \(error)")
            return
        }

        let workspaceID: String
        do { workspaceID = try WorkspaceStore.shared.current().id }
        catch {
            NSLog("AssistAnt: calendar_item.sync — cannot resolve workspace: \(error)")
            return
        }

        guard let from = CivilDate(iso: batch.from),
              let to = CivilDate(iso: batch.to)
        else {
            NSLog("AssistAnt: calendar_item.sync — bad window \(batch.from)..\(batch.to)")
            return
        }

        let iso = ISO8601DateFormatter()
        let now = Date()
        let items: [Item] = batch.items.compactMap { row in
            guard let startAt = iso.date(from: row.startAt) else {
                NSLog("AssistAnt: calendar_item.sync — skipping '\(row.title)': "
                    + "bad start_at \(row.startAt)")
                return nil
            }
            return Item(
                id: UUIDv7.generate(),
                workspaceID: workspaceID,
                type: ItemType.calendar.rawValue,
                title: row.title,
                body: row.body,
                source: batch.source,
                externalID: row.externalID,
                typeData: .calendar(CalendarData(
                    startAt: startAt,
                    endAt: row.endAt.flatMap(iso.date(from:)),
                    allDay: false,
                    timeZoneID: row.timeZone,
                    externalURL: row.externalURL)),
                iceboxedAt: nil,
                deletedAt: nil,
                scheduledOn: CivilDate(iso: row.scheduledOn),
                createdAt: now,
                updatedAt: now,
                serverUpdatedAt: nil,
                pending: true)
        }

        do {
            try GRDBItemStore.shared.applyCalendarSync(
                items: items, workspaceID: workspaceID, source: batch.source,
                from: from, to: to, keep: Set(batch.keep),
                allowEmptyKeep: false, prune: batch.prune)
            NSLog("AssistAnt: calendar_item.sync — upserted \(items.count), "
                + "prune=\(batch.prune)")
            // Tell windowed views + the sync indicators that calendar data
            // changed. The today sidebar already updates via its live store
            // observation; this covers the windowed Calendar agenda.
            NotificationCenter.default.post(
                name: .calendarItemsDidChange, object: nil)
        } catch {
            NSLog("AssistAnt: calendar_item.sync failed: \(error)")
        }
    }

    /// Apply an `actionable_item.sync` envelope: read the batch the CLI wrote
    /// (the open + recently-completed Linear issues plus the keep set), apply
    /// it (create / update / resolve + orphan reconcile) in one transaction,
    /// then delete the temp file.
    private func syncActionableItems(_ e: EventEnvelope) {
        guard let batchPath = e.detailValue("batch_file", as: String.self) else {
            NSLog("AssistAnt: actionable_item.sync missing batch_file")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: batchPath) }

        guard let data = FileManager.default.contents(atPath: batchPath) else {
            NSLog("AssistAnt: actionable_item.sync — batch file unreadable: \(batchPath)")
            return
        }
        let batch: ActionableSyncBatch
        do {
            batch = try JSONDecoder().decode(ActionableSyncBatch.self, from: data)
        } catch {
            NSLog("AssistAnt: actionable_item.sync — decode failed: \(error)")
            return
        }

        let workspaceID: String
        do { workspaceID = try WorkspaceStore.shared.current().id }
        catch {
            NSLog("AssistAnt: actionable_item.sync — cannot resolve workspace: \(error)")
            return
        }

        do {
            try GRDBItemStore.shared.applyActionableSync(
                rows: batch.items, workspaceID: workspaceID, source: batch.source,
                keep: Set(batch.keep), reconcile: batch.reconcile,
                allowEmptyKeep: false)
            NSLog("AssistAnt: actionable_item.sync — applied \(batch.items.count), "
                + "reconcile=\(batch.reconcile)")
            // Snapshot views (the Icebox) don't observe the store live; nudge
            // them to re-fetch now that actionable rows changed.
            NotificationCenter.default.post(
                name: .actionableItemsDidChange, object: nil)
        } catch {
            NSLog("AssistAnt: actionable_item.sync failed: \(error)")
        }
    }

    /// Apply an `actionable_item.create` envelope: build one manual actionable
    /// (todo/reminder/explore) and insert it. The disposition (manual source,
    /// unscheduled unless a day was named, never iceboxed) lives in
    /// `CapturedItem.make` so it stays unit-testable; this handler resolves the
    /// workspace, inserts, and nudges the snapshot views to re-fetch.
    private func createActionableItem(_ e: EventEnvelope) {
        let workspaceID: String
        do { workspaceID = try WorkspaceStore.shared.current().id }
        catch {
            NSLog("AssistAnt: actionable_item.create — cannot resolve workspace: \(error)")
            return
        }

        guard let item = CapturedItem.make(
            kind: e.detailValue("kind", as: String.self),
            title: e.detailValue("title", as: String.self),
            body: e.detailValue("body", as: String.self),
            scheduledOnISO: e.detailValue("scheduled_on", as: String.self),
            externalURL: e.detailValue("external_url", as: String.self),
            listName: e.detailValue("list_name", as: String.self),
            icebox: e.detailValue("icebox", as: Bool.self) ?? false,
            workspaceID: workspaceID
        ) else {
            NSLog("AssistAnt: actionable_item.create — invalid kind/title, skipping")
            return
        }

        do {
            try GRDBItemStore.shared.create(item)
            NSLog("AssistAnt: actionable_item.create — created \(item.type): \(item.title)")
            NotificationCenter.default.post(name: .actionableItemsDidChange, object: nil)
        } catch {
            NSLog("AssistAnt: actionable_item.create failed: \(error)")
        }
    }
}

extension Notification.Name {
    /// Posted by the actionable-sync handler right after it applies a Linear
    /// sync to the item store. Snapshot views that don't observe the store
    /// live (the Icebox) re-fetch on it.
    static let actionableItemsDidChange =
        Notification.Name("actionableItemsDidChange")

    /// Posted to bring the main window forward (e.g. after a Quick Capture
    /// "Ask" so the user watches the agent reply). Observed by AppDelegate.
    static let openMainWindow = Notification.Name("openMainWindow")
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
