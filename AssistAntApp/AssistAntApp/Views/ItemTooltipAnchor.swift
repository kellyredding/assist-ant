import SwiftUI
import AppKit

// MARK: - Row Frame Anchor

/// Holds a weak reference to an invisible NSView and computes its screen frame
/// on demand. Used to position the floating item-tooltip panel relative to a
/// SwiftUI row.
///
/// Querying the NSView's frame at hover time reads the live AppKit layout
/// directly: a frame stored in SwiftUI `@State` from `updateNSView` goes stale
/// during a live window resize (that callback only fires on SwiftUI state
/// changes, not AppKit layout passes), so the tooltip would render at the row's
/// previous on-screen position. Reading on demand eliminates that staleness.
///
/// Ported from Galaxy's `CollapsedSessionSidebar` row-anchor mechanism.
final class RowFrameAnchor {
    weak var view: NSView?

    /// The row's frame in screen coordinates (bottom-left origin, y-up — the
    /// same space as `NSWindow.frame`). Returns nil if the view has been
    /// removed from its window.
    func currentScreenFrame() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

/// Invisible `NSViewRepresentable` dropped behind a row via `.background(...)`
/// so callers can query that row's live frame on demand through a
/// `RowFrameAnchor`.
struct FrameAnchorView: NSViewRepresentable {
    let anchor: RowFrameAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
