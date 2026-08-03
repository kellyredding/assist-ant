import Galactic

/// This app's answer to *which* registry the Terminal tab's panes belong to.
///
/// Deliberately not hung off `AgentSessionController`, which owns a process and
/// would become a pane coordinator too. Galaxy keeps one of these per session
/// because its quit sheet names sessions; with one embedded session here, a
/// singleton is the same shape with the session dimension collapsed. The
/// mechanism itself is `TerminalPaneCoordinator` in the shared engine — what
/// belongs to this app is only the decision to keep exactly one.
///
/// The singleton is that answer, **not** the way consumers reach it. Anything
/// hostable — the terminal host above all — is handed a `TerminalPaneRegistry`
/// and never names `shared`, because the same host runs in an app that keeps
/// one per session, where a static would answer about the wrong one. App-level
/// chrome may name `shared` directly; that is the app choosing which registry,
/// which is exactly its business.
enum TerminalPanes {
    static let shared = TerminalPaneCoordinator()

    /// The panes themselves, so app chrome can name one while none holds first
    /// responder.
    ///
    /// The registry answers *which pane the user was last in* but never hands
    /// back the pane — its restorers return nothing, because restoring focus is
    /// all they were for. A menu command has to actually reach the pane to zoom
    /// or trim it, and the two questions want the same key, so they are kept
    /// side by side.
    ///
    /// Weak, and set rather than injected, for the reason the registry itself is
    /// a singleton here: the strong owners are the views that build these panes,
    /// and a pane that could not be released would keep a dead terminal
    /// reachable from the menu bar. Both clear themselves when their view lets
    /// go.
    static weak var sessionPane: SessionTerminalPane?
    static weak var shellPane: ShellTerminalPane?

    /// The pane of `kind`, if it is currently built.
    static func pane(kind: TerminalPaneKind) -> TerminalPane? {
        kind == .shell ? shellPane : sessionPane
    }
}
