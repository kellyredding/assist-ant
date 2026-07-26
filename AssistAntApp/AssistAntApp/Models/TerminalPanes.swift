import Foundation

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
final class TerminalPanes {
    static let shared = TerminalPanes()

    private init() {}

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
}
