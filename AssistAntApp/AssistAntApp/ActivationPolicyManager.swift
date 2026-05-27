import AppKit

/// Refcounts open windows. When the count goes from 0 -> 1, flips
/// activation policy to .regular (dock icon appears). When it
/// returns to 0, flips back to .accessory (dock icon disappears).
final class ActivationPolicyManager {
    private var openWindowCount = 0

    func windowOpened() {
        openWindowCount += 1
        if openWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
            // .regular does not activate; caller should call
            // NSApp.activate(ignoringOtherApps: true) after this.
        }
    }

    func windowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
