import AppKit

/// Drives Wispr Flow hands-free dictation via its (undocumented) URL scheme —
/// the reliable way on current macOS. `CGEvent` keystroke synthesis is filtered
/// by WindowServer's `CGXSenderCanSynthesizeEvents` gate (it drops synthetic
/// events unless the sender is WindowServer/kernel), so a synthesized hotkey
/// never reaches Wispr's listener. Opening `wispr-flow://…` routes straight to
/// Wispr's handler — **no Accessibility permission, no focus theft** (we open
/// without activating, like `open -g`).
///
/// Verified actions in Wispr Flow.app: `start-hands-free`, `stop-hands-free`,
/// `switch-mic`, `open`.
enum WisprArmer {
    /// Start hands-free dictation. Wispr types into whatever field is focused —
    /// so the popover's field must already hold focus when this fires.
    static func arm() { fire("start-hands-free") }

    /// Stop hands-free dictation (so the mic doesn't keep listening after the
    /// popover closes). Harmless if Wispr already stopped.
    static func stop() { fire("stop-hands-free") }

    private static func fire(_ action: String) {
        guard let url = URL(string: "wispr-flow://\(action)") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false // like `open -g` — keep focus on the popover field
        NSWorkspace.shared.open(url, configuration: cfg) { _, error in
            if let error {
                NSLog("WisprArmer: \(action) failed: \(error.localizedDescription)")
            }
        }
    }
}
