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

    /// Where configuration comes from, and how a change to it arrives.
    var settings: GalacticConfigurationSource { SettingsManager.shared }

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
        observeSettings(storingIn: &cancellables)
    }

    // MARK: - Lifecycle

    /// Launch the user's login shell in the resolved cwd.
    func start() {
        let shell = ShellEnvironment.userLoginShell()
        let cwd = ShellLauncher.resolveCwd()
        let env = ShellLauncher.buildEnvironment()

        applyCurrentSettings()

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
}
