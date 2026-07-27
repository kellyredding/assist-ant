import AppKit
import Combine

/// Which of the Terminal tab's two panes a host is showing.
enum TerminalPaneKind {
    case session
    case shell
}

/// Coordinator for the Terminal tab's panes — the registries that need to
/// reach across panes without either pane knowing about the other.
///
/// Deliberately not hung off `AgentSessionController`, which owns a process
/// and would become a pane coordinator too. Galaxy keeps the equivalent
/// registries on its per-session model; with one embedded session here, a
/// singleton is the same shape with the session dimension collapsed.
final class TerminalPanes: ObservableObject {
    static let shared = TerminalPanes()

    private init() {}

    /// True while the agent pane's scrollback overlay is open.
    ///
    /// Published because the shell pane's Send to Claude has to react to it:
    /// sending into the agent while its buffer is frozen open would land text
    /// the user can't see arriving. Lives here rather than on either pane, so
    /// neither has to know the other exists — and so it survives a pane being
    /// torn down and rebuilt.
    @Published private(set) var sessionPaneScrollbackActive: Bool = false

    func setSessionPaneScrollbackActive(_ active: Bool) {
        guard sessionPaneScrollbackActive != active else { return }
        sessionPaneScrollbackActive = active
    }

    /// The pane most recently holding first responder. Written by
    /// `TerminalHostView` when focus enters its subtree, and read when
    /// deciding which pane should take focus back.
    ///
    /// Only written on focus *entry*, never on exit, so focus moving to a
    /// text field elsewhere leaves the memory pointing at the pane the user
    /// was actually typing in. Defaults to the session pane, which is also
    /// the answer whenever no shell is open.
    var lastFocusedPaneKind: TerminalPaneKind = .session

    /// Focus restorers keyed by the registering host's identity, each tagged
    /// with the kind of pane it restores.
    ///
    /// This registry exists because SwiftUI hides an inactive tab by
    /// switching opacity, which never fires `updateNSView` — so AppKit
    /// quietly drops first responder and nothing puts it back. Restoring
    /// through the host rather than through the backend also lets the host
    /// redirect focus to an open scrollback overlay instead of the live
    /// terminal hidden beneath it.
    private var focusRestorers:
        [ObjectIdentifier: (kind: TerminalPaneKind, restore: () -> Void)] = [:]

    /// Register a host's focus restorer. Paired with
    /// `unregisterFocusRestorer` when the host goes away.
    func registerFocusRestorer(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        restore: @escaping () -> Void
    ) {
        focusRestorers[key] = (kind: kind, restore: restore)
    }

    func unregisterFocusRestorer(_ key: ObjectIdentifier) {
        focusRestorers.removeValue(forKey: key)
    }

    /// Restore focus to whichever pane the user was last in, falling back to
    /// the other if the preferred one is gone — the shell they remember
    /// typing in may have since closed. No-op when nothing is registered.
    func restorePreferredPaneFocus() {
        if let entry = focusRestorers.values
            .first(where: { $0.kind == lastFocusedPaneKind }) {
            entry.restore()
            return
        }
        // Session pane wins the fallback: it is the one that always exists.
        if let entry = focusRestorers.values
            .first(where: { $0.kind == .session }) {
            entry.restore()
            return
        }
        focusRestorers.values.first?.restore()
    }

    /// Restore focus to the session pane specifically, regardless of which
    /// pane was last focused. Used when a shell closes, where the memory
    /// still reads `.shell` from the user's final keystroke in it.
    func restoreSessionPaneFocus() {
        focusRestorers.values
            .first(where: { $0.kind == .session })?
            .restore()
    }

    /// Restore focus to the shell pane specifically. Used when the open-shell
    /// command arrives and a shell is already open, so the command means
    /// "focus it" rather than "open one".
    func restoreShellPaneFocus() {
        focusRestorers.values
            .first(where: { $0.kind == .shell })?
            .restore()
    }

    // MARK: - Unsaved scrollback work

    /// Per-host checks for unsaved scrollback work — committed notes not yet
    /// sent, an open note form with text, an edit in progress.
    ///
    /// Asynchronous because the answer lives in the scrollback overlay's web
    /// view and has to be fetched from JavaScript. Tagged by pane kind so a
    /// caller can ask about the panes whose loss actually matters to it.
    private var unsavedWorkCheckers:
        [ObjectIdentifier: (
            kind: TerminalPaneKind,
            check: (@escaping (Bool) -> Void) -> Void
        )] = [:]

    func registerUnsavedWorkChecker(
        _ key: ObjectIdentifier,
        kind: TerminalPaneKind,
        checker: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        unsavedWorkCheckers[key] = (kind: kind, check: checker)
    }

    func unregisterUnsavedWorkChecker(_ key: ObjectIdentifier) {
        unsavedWorkCheckers.removeValue(forKey: key)
    }

    /// Ask the matching panes whether they hold unsaved work and report back
    /// the subset that does, so a caller can name them. Checks run
    /// concurrently; the completion lands on main.
    func checkUnsavedWork(
        kinds: Set<TerminalPaneKind>,
        completion: @escaping (Set<TerminalPaneKind>) -> Void
    ) {
        let entries = unsavedWorkCheckers.values
            .filter { kinds.contains($0.kind) }
        guard !entries.isEmpty else {
            // Deliberately asynchronous even though the answer is known. The
            // quit path returns `terminateLater` and then replies from this
            // completion; replying synchronously, before that return, would
            // answer a question AppKit has not finished asking.
            DispatchQueue.main.async { completion([]) }
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var panesWithWork: Set<TerminalPaneKind> = []

        for entry in entries {
            group.enter()
            entry.check { hasWork in
                if hasWork {
                    lock.lock()
                    panesWithWork.insert(entry.kind)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(panesWithWork)
        }
    }

    /// Close the shell pane, confirming first when its scrollback holds notes
    /// that closing would discard. Unlike stopping the agent, there is no
    /// in-flight work to worry about here — unsaved notes are the only thing
    /// a shell close can destroy.
    func confirmAndCloseShellPane(onConfirm: @escaping () -> Void) {
        checkUnsavedWork(kinds: [.shell]) { panesWithWork in
            guard !panesWithWork.isEmpty else {
                onConfirm()
                return
            }
            guard let window = AppDelegate.shared?.windowForConfirmation()
            else { return }
            SheetAlert.confirm(
                in: window,
                message: "Close shell pane with unsaved scrollback notes?",
                detail: "Unsaved notes will be lost when the shell pane "
                    + "closes.",
                confirm: "Close",
                onConfirm: onConfirm
            )
        }
    }
}
