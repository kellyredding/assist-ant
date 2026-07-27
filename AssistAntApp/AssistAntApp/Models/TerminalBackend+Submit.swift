import Galactic

/// Prompt submission for text the app composed itself — Quick Capture,
/// scheduled tasks, Send to Claude, /clear, /compact. Kept in the app
/// (not Galactic) so the gesture needs no engine release: it rides
/// existing public protocol requirements. Mirrors Galaxy's
/// `TerminalBackend+Submit.swift`.
///
/// None of these are keystrokes the user pressed, so none of them may
/// depend on whichever keystroke the user bound to submit. Routing them
/// through one seam keeps automated submission correct when text-entry
/// settings change, instead of scattering the assumption across every
/// call site.
enum SessionSubmit {
    /// Bytes that Claude Code resolves to `chat:submit`.
    ///
    /// Claude Code is on its default `enter: chat:submit` until Galaxy
    /// writes a keybindings file, so a bare CR submits. Once Galaxy owns
    /// that file, this becomes the reserved chord Galaxy binds for its
    /// own use — automation then stops depending on whatever the user
    /// bound to Return.
    static var bytes: [UInt8] {
        [0x0D]
    }
}

extension TerminalBackend {
    /// Submit whatever was last written to this backend.
    ///
    /// Callers that pace the write and the submit across a delay must
    /// keep doing so; this changes the bytes sent, not when they're
    /// sent.
    func submitPrompt() {
        send(bytes: SessionSubmit.bytes)
    }
}
