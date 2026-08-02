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
}
