import AppKit
import Combine
import Galactic

/// Non-Claude interactive shell pane. Runs the user's login shell (`-il`)
/// in their home directory with the Claude context variables stripped.
///
/// Owns its own `TerminalBackend` for the PTY and rendering, independent of
/// the one `AgentSessionController` owns. That independence is why the shell
/// pane needs no multi-session refactor: the controller stays a singleton
/// owning the Claude side, and this pane sits beside it.
///
/// Ported from Galaxy's pane of the same name, minus its bell pipeline
/// (AssistAnt has no bell subsystem to route into) and its cross-session
/// focus-event suppression (no analog with a single session).
final class ShellTerminalPane: BackendBackedPane, ObservableObject {
    let backend: TerminalBackend

    /// The Claude session this pane sits beside — the Send-to-Claude target.
    /// A singleton here, where Galaxy holds a weak per-session reference.
    private let controller: AgentSessionController

    /// Per-shell-instance font size, in memory only. Seeded from the session
    /// pane's current size when the shell opens so the split looks coherent
    /// on first show, then diverges with ⌘+/⌘−.
    @Published var fontSize: CGFloat

    /// True while the shell process is running. Flips to false on exit, which
    /// the owning container observes to tear the pane down.
    @Published private(set) var isRunning: Bool = false

    var acceptsFileDrops: Bool { isRunning }

    var paneKind: TerminalPaneKind { .shell }

    // MARK: - Wired but unused here

    /// Forwarded to the engine so adopting bells here is genuinely supplying a
    /// closure. Nothing assigns it today, so bells go nowhere — but the path
    /// exists, which storage alone did not: a stored property would have
    /// accepted a closure and then never called it, because nothing carried the
    /// engine's callback to it.
    var onBell: (() -> Void)? {
        get { backend.onBell }
        set { backend.onBell = newValue }
    }

    var onProcessExit: ((Int32) -> Void)?

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        $fontSize.eraseToAnyPublisher()
    }

    private var cancellables = Set<AnyCancellable>()

    init(controller: AgentSessionController) {
        self.controller = controller
        // Pin the SwiftTerm engine, as the session backend does — AssistAnt
        // exposes no engine setting.
        self.backend = TerminalBackendFactory.make(
            engine: .swiftTerm,
            kind: .shell,
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        self.fontSize = controller.terminalFontSize
        wireBackend()
        subscribeToSettings()
    }

    // MARK: - Lifecycle

    /// Launch the user's login shell in the resolved cwd.
    func start() {
        let shell = ShellEnvironment.userLoginShell()
        let cwd = ShellLauncher.resolveCwd()
        let env = ShellLauncher.buildEnvironment()

        applyInitialAppearance()

        backend.startProcess(
            executable: shell,
            args: ["-il"],
            environment: env,
            execName: (shell as NSString).lastPathComponent,
            currentDirectory: cwd
        )

        isRunning = true
        NSLog("ShellTerminalPane: Started %@ in %@", shell, cwd)
    }

    /// Ask the shell to exit. Sends SIGHUP via the backend, which escalates
    /// to SIGTERM and then SIGKILL if the shell doesn't go. SIGHUP is the
    /// canonical terminal-hangup signal: most shells exit gracefully and
    /// flush history in response, with the harsher signals as the fallback
    /// for a misbehaving plugin. Exit fires `onProcessTerminated`, which
    /// clears `isRunning` and prompts teardown.
    func requestClose() {
        guard isRunning else { return }
        backend.terminateProcess(signal: SIGHUP)
    }

    // MARK: - Send to Claude

    /// The shell pane routes scrollback sends into the Claude session's
    /// terminal, not its own. Disabled while the agent isn't running.
    ///
    /// Goes through the controller's prompt queue rather than its backend so
    /// the send inherits the readiness wait and the pacing every other
    /// automated write to the agent's PTY uses. The second gate refuses to
    /// send while the agent pane's own scrollback is frozen open, since the
    /// text would arrive somewhere the user cannot see it.
    var sendToClaudeTarget: SendToClaudeTarget? {
        let controller = self.controller
        return SendToClaudeTarget(
            send: { controller.enqueuePrompt($0) },
            disabledReason: {
                // Agent-stopped takes precedence — it is the more
                // fundamental block, and saying "close scrollback" to
                // someone whose agent isn't running would send them to fix
                // the wrong thing.
                if controller.state != .running {
                    return "Start the agent first"
                }
                if TerminalPanes.shared.sessionPaneScrollbackActive {
                    return "Close agent scrollback first"
                }
                return nil
            }
        )
    }

    /// Where View ▸ Default returns to. The pane's own size is per-instance
    /// and in memory; this is the configured one every pane starts from.
    var defaultFontSize: CGFloat {
        SettingsManager.shared.settings.defaultTerminalFontSize
    }

    // MARK: - Private

    private func wireBackend() {
        backend.onProcessTerminated = { [weak self] exitCode in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRunning = false
                self.onProcessExit?(exitCode)
            }
        }
    }

    private func subscribeToSettings() {
        let mgr = SettingsManager.shared

        // Re-apply the settings model on any change, handing it this pane's
        // own size — the configured default is where a pane starts, not where
        // it is now. `dropFirst()` skips the initial value, which
        // `applyInitialAppearance` pushes explicitly at start time.
        mgr.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.backend.applySettings(
                    settings, fontSize: self.fontSize
                )
            }
            .store(in: &cancellables)

        // Cursor rides its own stream because the engine fuses shape and
        // blink into one style, so the pair is deduped as a unit. The same
        // settings drive the session pane's caret.
        mgr.$settings
            .map {
                TerminalCursorConfig(
                    style: $0.terminalCursorStyle,
                    blink: $0.terminalCursorBlink
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.backend.applyCursor(
                    style: config.style, blink: config.blink
                )
            }
            .store(in: &cancellables)
    }

    private func applyInitialAppearance() {
        let settings = SettingsManager.shared.settings
        backend.applySettings(settings, fontSize: fontSize)
        // Show the engine's native caret explicitly, as the session backend
        // does — a shell relies on the terminal to render its cursor.
        backend.setCaretHidden(false)
        backend.applyCursor(
            style: settings.terminalCursorStyle,
            blink: settings.terminalCursorBlink
        )
    }

    /// Push this pane's own size to the backend, for the zoom gestures.
    ///
    /// Only the font — a zoom has no business rebuilding the colour table or
    /// reallocating scrollback, which is why this is not a settings re-apply.
    func applyFontSize() {
        let family = SettingsManager.shared.settings.terminalFontFamily
        backend.setFont(
            resolveTerminalFont(family: family, size: fontSize)
        )
    }
}
