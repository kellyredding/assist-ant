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

    /// The persona this controller runs — the name of a TOML under
    /// ~/.claude-persona/personas/, read from the workspace record
    /// (Settings ▸ Workspace ▸ Persona). Falls back to the default when unset or
    /// unreadable. Read at spawn time, so a change takes effect on the next fresh
    /// session; it does not reach into a resumed conversation.
    private static var personaName: String {
        let stored = (try? WorkspaceStore.shared.current().personaName) ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Workspace.defaultPersonaName : trimmed
    }

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

    /// True between a resume spawn and the agent's `session:ready` — gates the
    /// one-shot post-resume reflow (replaces the old blind timer).
    private var awaitingResumeReady = false

    /// The agent this controller drives. The only place the app names one:
    /// everything vendor-specific about submitting a prompt — the bytes, the
    /// pacing, the readiness bound, what closes a completion popup — is
    /// reached through here rather than assumed.
    private let harness: AgentHarness = ClaudeCodeHarness()

    /// How many prompts the agent has reported taking, ever.
    ///
    /// A count rather than an in-turn flag, and the difference matters here.
    /// Galaxy can use a boolean because it suppresses verification whenever a
    /// turn is already running; this app queues prompts and drains them back
    /// to back, so the second is submitted while the agent is still working on
    /// the first. A flag would already be true, and every queued prompt after
    /// the first would verify against its predecessor's acceptance — reporting
    /// success without waiting for anything. Capturing the count at send time
    /// asks the question that actually matters: did another prompt land after
    /// mine went out.
    private var promptsAccepted = 0

    /// Verification for a prompt about to be sent.
    ///
    /// A function rather than a property because the baseline has to be read
    /// at the moment of sending. Built per send for that reason.
    private func submitVerification() -> SubmitVerification {
        let baseline = promptsAccepted
        return SubmitVerification(
            isAccepted: { [weak self] in
                guard let self else { return false }
                return self.promptsAccepted > baseline
            },
            isAlive: { [weak self] in self?.state == .running }
        )
    }

    /// The agent's UserPromptSubmit hook reported taking a prompt.
    ///
    /// The only honest evidence that an automated prompt landed. Everything
    /// observable from the terminal — the keyboard protocol flag, bytes
    /// received, screen content, output silence — was measured and every one
    /// reported ready against a prompt that did not exist.
    func recordPromptAccepted() {
        promptsAccepted &+= 1
        // Logged on the same channel as the sends it confirms, so a prompt and
        // its acceptance read as one exchange. An absent line here is the
        // symptom of a hook that never fired — which looks identical to a lost
        // prompt from every other vantage point.
        SessionSubmit.log("agent accepted a prompt (\(promptsAccepted) total)")
    }

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

    /// Handle a `session:ready` event from the workspace SessionStart hook.
    /// Adopts the current session id as the resume target — filtering out the
    /// extraction-sidecar sessions that share the workspace cwd — and fires the
    /// gated post-resume reflow. Keeps the persisted id current across `/clear`
    /// and `/compact` so the next launch resumes the live session, not a stale
    /// one. Main-thread (EventCoordinator dispatches the event there).
    func reconcileSession(id: String, source: String) {
        let decision = SessionReconciler.decide(
            source: source, reportedId: id,
            spawnedId: sessionId, awaitingResumeReady: awaitingResumeReady)
        guard !decision.ignored else { return }

        if let newId = decision.adoptId, newId != sessionId {
            sessionId = newId
            AgentStatePersistence.shared.saveSessionId(newId)
            NSLog("AgentSessionController: reconciled session id (%@) → %@",
                  source, newId)
        }
        if decision.reflow, awaitingResumeReady {
            awaitingResumeReady = false
            reflowBuffer()
        }
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

    /// Delay after one prompt is submitted before the next queued one is
    /// written, so the TUI finishes accepting one before the next arrives
    /// (batched task fires).
    ///
    /// This app's own number, unlike the gap between text and submit — that
    /// one is the agent's, and lives on the harness. This one is about not
    /// crowding a queue of the app's own making.
    private static let interPromptDelay: TimeInterval = 0.25

    /// Serial queue of prompts awaiting delivery.
    ///
    /// Task prompts are multi-line and are typed, not pasted — a bracketed
    /// paste is held as pending input and can swallow the submit that follows
    /// it. Typing is safe at any size because embedded newlines are LF and only
    /// a carriage return or the reserved chord commits.
    ///
    /// Draining one at a time is this app's own concern: scheduled tasks can
    /// fire together, and nothing else here keeps them from colliding in the
    /// input buffer.
    private var promptQueue: [String] = []
    private var drainingPrompts = false

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

    /// Submit whatever was last written — the automated counterpart to a
    /// keyboard Return. The harness owns the bytes, so this keeps working when
    /// text-entry settings change.
    ///
    /// Currently uncalled, and deliberately not the way to send anything:
    /// `sendCommand` and `enqueuePrompt` go through the shared delivery seam,
    /// which is what pairs a submit with a readiness wait, pacing and
    /// verification. A bare submit skips all three, so reaching for this is
    /// almost certainly a mistake.
    func submit() {
        guard state == .running, let backend else { return }
        backend.submitPrompt(harness: harness)
    }

    /// Enqueue a (possibly multi-line) prompt for delivery, each submitted on
    /// its own. The task runner's single delivery entry point: it types the
    /// prompt, waits, submits, then waits before the next — serializing
    /// batched fires so prompts don't collide in the input buffer.
    func enqueuePrompt(_ text: String) {
        guard state == .running else { return }
        promptQueue.append(text)
        drainPromptQueue()
    }

    private func drainPromptQueue() {
        guard !drainingPrompts, state == .running, let backend,
              !promptQueue.isEmpty else { return }
        drainingPrompts = true
        let text = promptQueue.removeFirst()

        SessionSubmit.log("queued prompt accepted=\(promptsAccepted)")

        backend.deliverPrompt(
            text,
            harness: harness,
            isAlive: { [weak self] in self?.state == .running },
            verification: submitVerification(),
            // Detected, never retyped, for two reasons — and the second is the
            // load-bearing one.
            //
            // These prompts are unbounded captured text, so a retype doubles a
            // prompt in the case where the text landed and only the submit was
            // lost, which nothing here can distinguish from a total loss.
            //
            // More importantly, this queue submits while the agent may still be
            // working, and Claude Code acknowledges a prompt when it dequeues
            // one rather than when it is typed. A prompt sent mid-turn was
            // measured acknowledged 20s after its submit — ten times the verify
            // bound — and it landed correctly. Retyping on that signal would
            // re-run a scheduled task, unattended, for no fault at all. The
            // bound is honest for an idle agent and meaningless for a busy one,
            // so the report is informational here.
            //
            // Fixing that properly needs a turn-end signal this app does not
            // have (Galaxy installs a Stop hook for it), and gating the queue on
            // turn end would make batched tasks drain a turn apart instead of
            // together. Deliberately not done: the current behaviour is correct,
            // only slower to confirm.
            retry: .reportOnly,
            then: { [weak self] in
                guard let self else { return }
                // Released after the gap, on every path — an abandoned send
                // must free the queue too, or it strands behind a prompt that
                // never got written.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.interPromptDelay
                ) {
                    self.drainingPrompts = false
                    self.drainPromptQueue()
                }
            }
        )
    }

    /// Send a slash command and submit it.
    ///
    /// The gesture itself is shared with Galaxy; what stays here is this app's
    /// policy. Missing, relative to Galaxy: the synthetic-turn bookkeeping,
    /// which depends on turn-state events the embedded session does not
    /// observe.
    ///
    /// Verified against the agent's own report that it took the prompt, which
    /// arrives over the socket from its UserPromptSubmit hook. Retyped on a
    /// loss, unlike the queue path: these payloads are bounded slash commands,
    /// so a second copy costs little and a missing `/clear` costs a lot.
    func sendCommand(_ command: String) {
        guard state == .running, let backend else {
            SessionSubmit.log("sendCommand refused — session not running")
            return
        }

        // These bypass the agent's prompt pipeline, so its hook never fires for
        // them and no acceptance report is coming. Waiting on one would be
        // waiting on nothing — the opt-out is a value, and this is the reason
        // for it.
        let bypasses = harness.acceptanceBypassingCommands.contains(
            command.trimmingCharacters(in: .whitespaces))

        SessionSubmit.log(
            "sendCommand accepted=\(promptsAccepted) bypasses=\(bypasses)")

        backend.deliverPrompt(
            command,
            harness: harness,
            isAlive: { [weak self] in self?.state == .running },
            verification: bypasses ? nil : submitVerification()
        )
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
        // GalacticConfiguration, so applySettings reads the family, scrollback
        // and theme straight from it; the size is this surface's own.
        let settings = SettingsManager.shared.settings
        // Seed the transient zoom level from the persisted default so a
        // session restart returns to it (transient-reset semantics). Seeded
        // before the apply below, which now takes the size it should use.
        terminalFontSize = settings.defaultTerminalFontSize
        backend.applySettings(settings, fontSize: terminalFontSize)
        // Show the engine's native caret — it IS Claude's prompt
        // cursor (Claude does not self-render one, so hiding it left
        // no visible cursor). Shape and blink come from settings; their
        // defaults are a steady block (matching Galaxy / Terminal /
        // Ghostty) rather than the engine's blinking-block default.
        backend.setCaretHidden(false)
        backend.applyCursor(
            style: settings.terminalCursorStyle,
            blink: settings.terminalCursorBlink
        )

        // Re-apply settings live when prefs change (font / size /
        // scrollback / cursor).
        settingsCancellable = SettingsManager.shared.$settings
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self, let backend = self.backend else { return }
                // The size stays this surface's own. Changing the configured
                // default used to overwrite the live zoom here, on the reasoning
                // that a settings change should become the new baseline — but
                // that silently discarded a zoom the user had set, and it moved
                // the cell geometry, which makes the agent's full-screen UI
                // repaint. The default is where a surface starts, not where it
                // is now.
                backend.applySettings(
                    settings, fontSize: self.terminalFontSize
                )
                // Cursor rides the same stream: applySettings covers only
                // the GalacticConfiguration members, so shape and blink
                // need their own call to take effect without a restart.
                backend.applyCursor(
                    style: settings.terminalCursorStyle,
                    blink: settings.terminalCursorBlink
                )
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

        // Mark running synchronously so the Agent pane swaps to the terminal
        // now; the PTY spawn happens on the main-thread hop below once the
        // environment is captured. The resume reflow gating below also reads
        // this state, so it must be set before that runs.
        state = .running

        // On resume the freshly-built backend can show a resize artifact until
        // the restored TUI repaints. Rather than guess a delay, we reflow when
        // the agent's `session:ready` arrives (see reconcileSession) — the
        // SessionStart hook fires once the resumed TUI is up, matching Galaxy's
        // session:ready gating. A longer fallback timer covers a lost or
        // never-delivered event so the screen can never stay garbled. A fresh
        // start needs no reflow — it opens on a clean screen. The 3s window
        // comfortably outlasts the off-main env capture (~0.2-0.3s) plus the
        // spawn below.
        if resume {
            awaitingResumeReady = true
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 3.0
            ) { [weak self] in
                guard let self, self.awaitingResumeReady else { return }
                self.awaitingResumeReady = false
                self.reflowBuffer()
            }
        }

        NSLog(
            "AgentSessionController: %@ persona '%@' session %@ in %@",
            resume ? "Resuming" : "Starting",
            Self.personaName, sessionId, cwd
        )

        // Capturing the login-shell environment sources the user's profile
        // (~0.2-0.3s), so build it off the main thread and spawn back on
        // main. This gives the session the same environment a terminal gets
        // — profile secrets, full PATH, locale — instead of launchd's
        // minimal env.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let environment = Self.buildEnvironment()

            DispatchQueue.main.async { [weak self] in
                guard let self, let backend = self.backend else { return }
                backend.startProcess(
                    executable: execPath,
                    args: args,
                    environment: environment,
                    execName: "claude-persona",
                    currentDirectory: cwd
                )
            }
        }
    }

    private func teardown() {
        settingsCancellable?.cancel()
        settingsCancellable = nil
        backend?.onProcessTerminated = nil
        backend = nil
    }

    // MARK: - Environment

    /// Build the child environment. Runs OFF the main thread because the
    /// login-shell capture sources the user's profile (~0.2-0.3s).
    ///
    /// Base is the user's login-shell environment so the session matches a
    /// terminal — profile-exported secrets, the full PATH, locale. Falls
    /// back to this process's own (launchd-minimal) environment if the
    /// capture fails, so the session can always start. On top of the base it
    /// strips vars that interfere with a nested Claude session, forces a
    /// known-good TERM/LANG, and ensures ~/.local/bin is on PATH so
    /// claude-persona can find `claude`.
    private static func buildEnvironment() -> [String] {
        // Base: the login shell's environment; fall back to this process's
        // own environment if the capture fails.
        var env: [String] = ShellEnvironment.loginShellEnvironment()
            ?? ProcessInfo.processInfo.environment.map {
                "\($0.key)=\($0.value)"
            }

        // Strip vars that interfere with a child Claude session:
        // - TERM/COLORTERM/LANG: overridden below.
        // - CLAUDECODE: set by a running Claude Code session; inherited it
        //   blocks the child from starting (nested-session guard).
        // - CLAUDE_CLI_SESSION_ID: set by a parent persona session;
        //   inherited it would mis-resolve hooks to the parent.
        // - CLAUDE_CODE_*: when the app is launched from inside a Claude Code
        //   session (an agent restarting it via `open`), CLAUDE_CODE_SESSION_ID
        //   and CLAUDE_CODE_CHILD_SESSION leak in. The embedded Claude then
        //   treats itself as a nested child and writes its transcript under a
        //   freshly minted id instead of the --session-id we pass, so the
        //   persisted resume target has no transcript and the next --resume
        //   exits with "No conversation found" (the agent dies on restart).
        //   Drop the whole family so the child always runs as a clean
        //   top-level session no matter how the app was launched.
        // - TERM_PROGRAM/_VERSION/_SESSION_ID: whichever terminal launched the
        //   app. Replaced below rather than passed through — an inherited
        //   identity would either win outright or leave a version or session
        //   string describing a different terminal than the one being claimed,
        //   and a half-replaced identity is harder to diagnose than an absent
        //   one because each field reads as plausible alone.
        env = env.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("COLORTERM=") &&
            !$0.hasPrefix("LANG=") &&
            !TerminalIdentity.isInherited($0) &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=") &&
            !$0.hasPrefix("CLAUDE_CODE_")
        }
        env.append("TERM=xterm-256color")

        // Claude Code enables the kitty keyboard protocol only for a terminal
        // identity it recognises, and that protocol is what carries a modified
        // Return. Without it the reserved machine-submit chord reaches the child
        // as a bare carriage return, indistinguishable from Return itself.
        env.append(TerminalIdentity.declaration)
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
