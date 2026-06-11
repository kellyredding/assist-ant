import AppKit
import Combine
import Galactic

/// Lifecycle state of the embedded agent session.
enum AgentSessionState: Equatable {
    case starting
    case running
    case stopped
    case failed(reason: AgentFailureReason)
}

/// A classified startup failure with a user-facing message and a fix
/// suggestion. Each case names what AssistAnt expected and how to resolve
/// it.
enum AgentFailureReason: Equatable {
    /// `claude-persona` binary not found on any known path or via `which`.
    case binaryNotFound
    /// The persona TOML for `assist-ant` is missing.
    case personaMissing(path: String)
    /// The workspace cwd does not exist (symlink not set up).
    case workspaceMissing(path: String)
    /// Process failed to spawn for some other reason.
    case spawnFailed(detail: String)

    var title: String {
        switch self {
        case .binaryNotFound: return "claude-persona not found"
        case .personaMissing: return "assist-ant persona missing"
        case .workspaceMissing: return "Workspace not set up"
        case .spawnFailed: return "Could not start the agent"
        }
    }

    /// What AssistAnt expected, in one line.
    var expectation: String {
        switch self {
        case .binaryNotFound:
            return "AssistAnt looked for the `claude-persona` "
                + "executable on ~/.local/bin, /usr/local/bin, and "
                + "/opt/homebrew/bin, and on your PATH."
        case .personaMissing(let path):
            return "AssistAnt expected the persona file at \(path)."
        case .workspaceMissing(let path):
            return "AssistAnt expected the agent's working directory "
                + "at \(path)."
        case .spawnFailed(let detail):
            return detail
        }
    }

    /// How to fix it.
    var fixSuggestion: String {
        switch self {
        case .binaryNotFound:
            return "Install claude-persona (see its README) and "
                + "relaunch AssistAnt."
        case .personaMissing:
            return "Create the persona with "
                + "`claude-persona generate`, or restore the "
                + "assist-ant.toml file, then retry."
        case .workspaceMissing:
            return "Create the Sync workspace target and symlink "
                + "~/.assist-ant/workspace to it (see the AssistAnt "
                + "setup notes), then retry."
        case .spawnFailed:
            return "Check Console.app for AssistAnt logs, then retry."
        }
    }
}

/// Owns the single embedded `assist-ant` Claude session for the whole app
/// lifetime. App-level (not window-level) so closing the main window leaves
/// the session running; reopening re-mounts the same `backend.view`.
///
/// Spawn details mirror a persona Claude session: the same env strip/re-add
/// recipe, the same arg shape (claude-persona <persona>
/// --session-id|--resume <uuid>), and the same binary resolution.
/// Differences: one session only, no `--vibe` (the persona's permission
/// mode already covers it), and CLAUDE_CLI_SESSION_ID is never appended
/// (claude-persona injects it via its --settings hook).
final class AgentSessionController: ObservableObject {
    static let shared = AgentSessionController()

    /// The persona this controller runs. Matches the persona TOML filename
    /// under ~/.claude-persona/personas/.
    private static let personaName = "assist-ant"

    @Published private(set) var state: AgentSessionState = .stopped

    /// The Galactic terminal backend. Non-nil while running; released on
    /// exit to free the scrollback buffer. The Agent pane reads
    /// `backend?.view` when state is `.running`.
    @Published private(set) var backend: TerminalBackend?

    /// Live, transient terminal font size for the embedded session — the
    /// analog of Galaxy's per-`Session` `terminalFontSize`. Driven by the
    /// View ▸ Bigger / Smaller / Default keyboard zoom and applied to the
    /// backend immediately. NOT persisted: `resetFontSize()` snaps it back
    /// to `AppSettings.defaultTerminalFontSize` and it is re-seeded on each
    /// spawn. Published so a future scrollback overlay can re-render on a
    /// font change.
    @Published private(set) var terminalFontSize: CGFloat =
        AppSettings.current.defaultTerminalFontSize

    /// The current Claude session id (lowercased UUID). Persisted to
    /// AgentStatePersistence so relaunch resumes it.
    private(set) var sessionId: String?

    /// Resolved path to the claude-persona executable, or nil if not found.
    /// Resolved once at init.
    private let personaBinaryPath: String?

    private var settingsCancellable: AnyCancellable?

    private init() {
        self.personaBinaryPath = Self.findBinaryPath(name: "claude-persona")
        self.sessionId = AgentStatePersistence.shared.loadSessionId()
    }

    // MARK: - Public lifecycle

    /// Called from AppDelegate on launch. Resumes the persisted session if
    /// one exists; otherwise generates a new id, persists it, and starts
    /// fresh.
    func startOnLaunch() {
        guard backend == nil else { return }  // already running
        if let existing = sessionId {
            spawn(sessionId: existing, resume: true)
        } else {
            let newId = UUID().uuidString.lowercased()
            sessionId = newId
            AgentStatePersistence.shared.saveSessionId(newId)
            spawn(sessionId: newId, resume: false)
        }
    }

    /// Start a brand-new session, discarding any stored id. Wired to the
    /// Start button shown after the agent stops or fails. The fresh id is
    /// deliberate: resuming carries the original persona prompt and
    /// CLAUDE.md forward in the session's context, so edits to either are
    /// only picked up by a session that starts clean. The new id is
    /// persisted, so the next launch resumes this conversation.
    func startFresh() {
        guard backend == nil else { return }
        let newId = UUID().uuidString.lowercased()
        sessionId = newId
        AgentStatePersistence.shared.saveSessionId(newId)
        spawn(sessionId: newId, resume: false)
    }

    /// Terminate the running session — called on app quit so the child
    /// process tree (claude-persona → claude → MCP servers) is reaped at a
    /// controlled point rather than left for the PTY hangup to chase down.
    /// The session id stays persisted, so the next launch resumes the same
    /// conversation.
    func stop() {
        guard let backend else { return }
        backend.terminateProcess(signal: SIGHUP)
        teardown()
        state = .stopped
    }

    // MARK: - Terminal font zoom (transient)

    /// Bump the live font one step toward the ceiling and apply it to the
    /// backend immediately. Mirrors Galaxy
    /// `Session.increaseTerminalFontSize` (via
    /// `SessionTerminalPane.increaseFontSize()`).
    func increaseFontSize() {
        setFontSize(
            min(
                terminalFontSize + AppSettings.terminalFontSizeStep,
                AppSettings.terminalFontSizeRange.upperBound
            )
        )
    }

    /// Drop the live font one step toward the floor.
    func decreaseFontSize() {
        setFontSize(
            max(
                terminalFontSize - AppSettings.terminalFontSizeStep,
                AppSettings.terminalFontSizeRange.lowerBound
            )
        )
    }

    /// Snap the live font back to the persisted default. The reset target
    /// is the *setting*, not a constant — matches Galaxy
    /// `Session.resetTerminalFontSize`.
    func resetFontSize() {
        setFontSize(SettingsManager.shared.settings.defaultTerminalFontSize)
    }

    /// True while the live size is below the ceiling. Drives the
    /// View ▸ Bigger item's enabled state.
    var canIncreaseFontSize: Bool {
        terminalFontSize < AppSettings.terminalFontSizeRange.upperBound
    }

    /// True while the live size is above the floor.
    var canDecreaseFontSize: Bool {
        terminalFontSize > AppSettings.terminalFontSizeRange.lowerBound
    }

    /// Apply a clamped font size to the live backend. No-op when the
    /// session isn't running or the size is unchanged.
    private func setFontSize(_ size: CGFloat) {
        guard let backend, size != terminalFontSize else { return }
        terminalFontSize = size
        backend.setFont(
            resolveTerminalFont(
                family: SettingsManager.shared.settings.terminalFontFamily,
                size: size
            )
        )
    }

    // MARK: - Buffer

    /// Agent ▸ Trim Buffer — drop the scrollback history and reflow the
    /// viewport onto a clean screen. Mirrors Galaxy
    /// `SessionTerminalPane.trimBuffer()` → `TerminalBackend.trimBuffer()`.
    /// No-op when the session isn't running.
    func trimBuffer() {
        guard state == .running, let backend else { return }
        backend.trimBuffer()
    }

    /// Agent ▸ Reflow Buffer — redraw the current screen in place without
    /// trimming scrollback. Mirrors Galaxy
    /// `SessionTerminalPane.reflowBuffer()` → `TerminalBackend.reflowBuffer()`.
    /// No-op when the session isn't running.
    func reflowBuffer() {
        guard state == .running, let backend else { return }
        backend.reflowBuffer()
    }

    // MARK: - Send to session (PTY)

    /// Delay between writing command text and sending CR, so the TUI
    /// registers the text as input before Enter arrives. Mirrors Galaxy
    /// `Session.commandSubmitDelay` (100ms).
    private static let commandSubmitDelay: TimeInterval = 0.1

    /// Write text into the running session's PTY. `asPaste` wraps the text
    /// in bracketed-paste sequences when the terminal has bracketed-paste
    /// mode on (the backend handles the wrapping). The single seam every
    /// PTY-write feature rides: the slash commands here, a scrollback
    /// overlay's "Send to Claude", and a future briefing trigger. Mirrors
    /// Galaxy `TerminalPane.send(text:asPaste:)`. No-op when not running.
    func send(text: String, asPaste: Bool) {
        guard state == .running, let backend else { return }
        backend.send(text: text, asPaste: asPaste)
    }

    /// Send a single CR (0x0D) to submit whatever was last written — the
    /// same byte as a keyboard Return. Mirrors Galaxy's inline
    /// `backend.send(bytes: [0x0D])` in `Session.sendCommand`.
    func submit() {
        guard state == .running, let backend else { return }
        backend.send(bytes: [0x0D])
    }

    /// Send a slash command and submit it after `commandSubmitDelay`.
    /// Mirrors the send-text → delay → CR core of Galaxy
    /// `Session.sendCommand`, minus Galaxy's socket-driven verify/retry and
    /// synthetic-turn bookkeeping (which depend on turn-state events the
    /// embedded session does not observe).
    func sendCommand(_ command: String) {
        guard state == .running, let backend else {
            NSLog(
                "AgentSessionController: cannot send '%@' — not running",
                command
            )
            return
        }
        backend.send(text: command, asPaste: false)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.commandSubmitDelay
        ) { [weak self] in
            guard let self, self.state == .running else { return }
            self.backend?.send(bytes: [0x0D])
        }
    }

    /// Agent ▸ Clear session — trim the terminal scrollback first so the
    /// reset session opens on a clean buffer (/clear resets Claude's own
    /// rendering, not the terminal's scrollback history), then send /clear.
    /// Mirrors Galaxy `SessionManager.clearAndHandoff`'s trim-then-command
    /// step (minus Galaxy's multi-session handoff machinery).
    func clearSession() {
        trimBuffer()
        sendCommand("/clear")
    }

    /// Agent ▸ Compact session — same trim-then-command as `clearSession`.
    /// Mirrors Galaxy `SessionManager.compactActiveSession`.
    func compactSession() {
        trimBuffer()
        sendCommand("/compact")
    }

    // MARK: - Spawn / teardown

    private func spawn(sessionId: String, resume: Bool) {
        state = .starting

        // Pre-flight: surface specific, actionable failures before the
        // generic spawn path swallows them.
        guard let execPath = personaBinaryPath else {
            state = .failed(reason: .binaryNotFound)
            return
        }
        let personaPath = NSHomeDirectory()
            + "/.claude-persona/personas/\(Self.personaName).toml"
        guard FileManager.default.fileExists(atPath: personaPath) else {
            state = .failed(reason: .personaMissing(path: personaPath))
            return
        }
        let cwd = AssistAntPaths.workspaceDir.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: cwd, isDirectory: &isDir
        ), isDir.boolValue else {
            state = .failed(reason: .workspaceMissing(path: cwd))
            return
        }

        // Build the backend. Single session, .session pane kind, SwiftTerm
        // engine (no engine setting here; pin the default the factory
        // ships).
        let backend = TerminalBackendFactory.make(
            engine: .swiftTerm,
            kind: .session,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        // Apply settings + font. AppSettings conforms to
        // GalacticConfiguration, so applySettings reads font family, size,
        // scrollback, and the hardcoded theme straight from it.
        let settings = SettingsManager.shared.settings
        backend.applySettings(settings)
        backend.setFont(
            resolveTerminalFont(
                family: settings.terminalFontFamily,
                size: settings.defaultTerminalFontSize
            )
        )
        // Seed the transient zoom level from the persisted default so a
        // session restart returns to it (transient-reset semantics).
        terminalFontSize = settings.defaultTerminalFontSize
        // Show the engine's native caret — it IS Claude's prompt
        // cursor (Claude does not self-render one, so hiding it left
        // no visible cursor). No cursor-settings UI here yet, so
        // default to a steady block (matches Galaxy / Terminal /
        // Ghostty) rather than the engine's blinking-block default.
        backend.setCaretHidden(false)
        backend.applyCursor(style: .block, blink: false)

        // Re-apply settings live when prefs change (font / size /
        // scrollback).
        settingsCancellable = SettingsManager.shared.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let backend = self?.backend else { return }
                backend.applySettings(settings)
                backend.setFont(
                    resolveTerminalFont(
                        family: settings.terminalFontFamily,
                        size: settings.defaultTerminalFontSize
                    )
                )
                // A settings-driven font change is the new transient
                // baseline, so live zoom and the persisted default agree.
                self?.terminalFontSize = settings.defaultTerminalFontSize
            }

        // Transition to stopped when the child exits. No auto-restart: a
        // deliberate /exit must stay exited, and auto-restart would turn a
        // crash-on-launch into a tight loop.
        backend.onProcessTerminated = { [weak self] _ in
            DispatchQueue.main.async {
                self?.teardown()
                self?.state = .stopped
            }
        }

        self.backend = backend

        // Build the environment.
        let environment = Self.buildEnvironment()

        // Build args: claude-persona <persona> --session-id|--resume <id>.
        // No --vibe (the persona's permission mode covers it). No
        // CLAUDE_CLI_SESSION_ID in the env (claude-persona injects it via
        // its own --settings mechanism for persona sessions).
        var args: [String] = [Self.personaName]
        if resume {
            args.append("--resume")
        } else {
            args.append("--session-id")
        }
        args.append(sessionId)

        backend.startProcess(
            executable: execPath,
            args: args,
            environment: environment,
            execName: "claude-persona",
            currentDirectory: cwd
        )

        state = .running

        // On resume the freshly-built backend can come back showing a
        // resize artifact until the restored view repaints, and only the
        // child repainting clears it. There's no deterministic "rendered"
        // signal here, so mirror Galaxy's post-resume reflow: send a form
        // feed on a short fixed delay once the resumed TUI is up. A fresh
        // start needs no reflow — it opens on a clean screen. Starting knob;
        // raise the delay if the garble sometimes outlives it. (Galaxy uses
        // 0.25s, but it reflows after sending a resume command to an
        // already-running session, whereas this fires after a fresh process
        // launch, which needs longer to bring its TUI up.)
        if resume {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.75
            ) { [weak self] in
                self?.reflowBuffer()
            }
        }

        NSLog(
            "AgentSessionController: %@ persona '%@' session %@ in %@",
            resume ? "Resuming" : "Starting",
            Self.personaName, sessionId, cwd
        )
    }

    private func teardown() {
        settingsCancellable?.cancel()
        settingsCancellable = nil
        backend?.onProcessTerminated = nil
        backend = nil
    }

    // MARK: - Environment

    /// Build the child environment. Strips vars that interfere with a
    /// nested Claude session, forces a known-good TERM/LANG, and ensures
    /// ~/.local/bin is on PATH so claude-persona can find `claude`.
    private static func buildEnvironment() -> [String] {
        var env: [String] = ProcessInfo.processInfo.environment.map {
            "\($0.key)=\($0.value)"
        }

        // Strip vars that interfere with a child Claude session:
        // - TERM/COLORTERM/LANG: overridden below.
        // - CLAUDECODE: set by a running Claude Code session; inherited it
        //   blocks the child from starting (nested-session guard).
        // - CLAUDE_CLI_SESSION_ID: set by a parent persona session;
        //   inherited it would mis-resolve hooks to the parent.
        env = env.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("COLORTERM=") &&
            !$0.hasPrefix("LANG=") &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=")
        }
        env.append("TERM=xterm-256color")
        // Deliberately NOT COLORTERM=truecolor: without it Claude Code uses
        // ANSI indexed colors driven by the installed palette, matching
        // Terminal.app's rendering. Setting it would make Claude Code emit
        // 24-bit RGB from its own theme and bypass the palette.
        env.append("LANG=en_US.UTF-8")

        // Ensure ~/.local/bin is on PATH. A GUI app inherits launchd's
        // minimal PATH, which omits ~/.local/bin where `claude` often lives
        // — claude-persona resolves `claude` via PATH lookup.
        let localBin = "\(NSHomeDirectory())/.local/bin"
        if let i = env.firstIndex(where: { $0.hasPrefix("PATH=") }) {
            if !env[i].contains(localBin) {
                env[i] = "\(env[i]):\(localBin)"
            }
        } else {
            env.append(
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:\(localBin)"
            )
        }

        return env
    }

    // MARK: - Binary resolution

    /// Resolve a binary by checking common install paths, then falling back
    /// to `which`.
    private static func findBinaryPath(name: String) -> String? {
        let searchPaths = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !out.isEmpty {
                return out
            }
        } catch {
            // Ignore — fall through to nil.
        }
        return nil
    }
}
