import AppKit
import Combine
import Galactic

/// Pair wrapper over (style, blink) so Combine can dedupe the two as a single
/// unit. Without it, independent subscriptions on `terminalCursorStyle` and
/// `terminalCursorBlink` would each fire `applyCursor` on init; this lets one
/// `.removeDuplicates()` guard the combined signal.
private struct ShellCursorConfig: Hashable {
    let style: ShellCursorStyle
    let blink: Bool
}

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
final class ShellTerminalPane: TerminalPane, ObservableObject {
    private let backend: TerminalBackend

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

    var view: NSView { backend.view }
    var isAcceptingInput: Bool { isRunning }

    var onProcessExit: ((Int32) -> Void)?

    var viewportRow: Int { backend.viewportRow }
    func clearSelection() { backend.clearSelection() }

    var font: NSFont { backend.font }
    var cellHeight: CGFloat { backend.cellHeight }
    func snapViewportToBottom() { backend.snapViewportToBottom() }

    func redraw() { backend.redraw() }

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

    // MARK: - Terminal surface

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        backend.captureScrollbackSnapshot()
    }

    func send(text: String, asPaste: Bool) {
        backend.send(text: text, asPaste: asPaste)
    }

    func focus() { backend.focus() }

    func trimBuffer() { backend.trimBuffer() }

    func reflowBuffer() { backend.reflowBuffer() }

    func reassertFollowIfIntended() { backend.reassertFollowIfIntended() }

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

    // MARK: - Font size

    func increaseFontSize() {
        let step = AppSettings.terminalFontSizeStep
        let range = AppSettings.terminalFontSizeRange
        fontSize = min(fontSize + step, range.upperBound)
        applyPerPaneFontSize()
    }

    func decreaseFontSize() {
        let step = AppSettings.terminalFontSizeStep
        let range = AppSettings.terminalFontSizeRange
        fontSize = max(fontSize - step, range.lowerBound)
        applyPerPaneFontSize()
    }

    /// Reset to the global default terminal font size, so View ▸ Default
    /// behaves the same in either pane.
    func resetFontSize() {
        fontSize = SettingsManager.shared.settings.defaultTerminalFontSize
        applyPerPaneFontSize()
    }

    var canIncreaseFontSize: Bool {
        fontSize < AppSettings.terminalFontSizeRange.upperBound
    }

    var canDecreaseFontSize: Bool {
        fontSize > AppSettings.terminalFontSizeRange.lowerBound
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

        // Re-apply the settings model on any change. `applySettings` covers
        // the GalacticConfiguration members (font family, scrollback, theme);
        // per-pane font size sits outside that model and is applied after.
        // `dropFirst()` skips the initial value, which
        // `applyInitialAppearance` pushes explicitly at start time.
        mgr.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.backend.applySettings(settings)
                self?.applyPerPaneFontSize()
            }
            .store(in: &cancellables)

        // Cursor rides its own stream because the engine fuses shape and
        // blink into one style, so the pair is deduped as a unit. The same
        // settings drive the session pane's caret.
        mgr.$settings
            .map {
                ShellCursorConfig(
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
        backend.applySettings(settings)
        applyPerPaneFontSize()
        // Show the engine's native caret explicitly, as the session backend
        // does — a shell relies on the terminal to render its cursor.
        backend.setCaretHidden(false)
        backend.applyCursor(
            style: settings.terminalCursorStyle,
            blink: settings.terminalCursorBlink
        )
    }

    /// Apply the per-pane font-size override to the backend.
    /// `applySettings` installs the global default size; this replaces it
    /// with this pane's own value.
    private func applyPerPaneFontSize() {
        let family = SettingsManager.shared.settings.terminalFontFamily
        backend.setFont(
            resolveTerminalFont(family: family, size: fontSize)
        )
    }
}
