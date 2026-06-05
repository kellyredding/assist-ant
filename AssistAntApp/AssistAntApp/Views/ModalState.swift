import AppKit

/// Detects whether a modal presentation is currently on top of a
/// given window. Drag-and-drop targets call this to refuse drops
/// while the user is being asked to make a modal decision —
/// preventing both the stale-render bug (drop bytes accepted but
/// view not repainted until a later event) and the broader UX
/// issue of accepting input the user can't see they're directing.
///
/// Two mechanisms are covered:
/// 1. App-modal windows presented via `NSApp.runModal(for:)`
///    (Settings, New Session, Restore Session).
/// 2. Window-modal sheets presented via
///    `NSAlert.beginSheetModal(for:)` — every confirmation dialog
///    in the app goes through `SheetAlert.confirm`, which uses
///    this mechanism.
///
/// If a third presentation mechanism is added later (e.g. a
/// custom SwiftUI overlay used as a modal), extend this helper
/// rather than the individual drag handlers.
enum ModalState {
    /// True when a modal is currently presenting over `window`.
    /// Pass the drag-target view's own `window` — sheet
    /// attachment is per-window, so the helper needs the context.
    static func isPresenting(over window: NSWindow?) -> Bool {
        if NSApp.modalWindow != nil { return true }
        if window?.attachedSheet != nil { return true }
        return false
    }
}
