import SwiftUI
import AppKit

extension View {
    /// Makes the view act as a clickable control that shows the
    /// pointing-hand cursor while hovered, and reports hover changes.
    ///
    /// Exists because SwiftUI on macOS gives plain buttons no pointer
    /// cursor, and setting `NSCursor` from `.onHover` / `.onContinuousHover`
    /// loses a per-event race: the hosting view re-asserts the arrow on
    /// every mouse-moved pass, *after* those callbacks fire, so the cursor
    /// flickers between hand and arrow. The reliable hook is
    /// `NSView.cursorUpdate(with:)` — AppKit calls it last, as the final
    /// say on the cursor, but only on the topmost hit view. So this overlay
    /// is hit-testable and owns the click too (calling `action`), rather
    /// than trying to pass clicks through to a SwiftUI button beneath it.
    ///
    /// Note: do not place this overlay under a `scaleEffect` (or other
    /// geometry transform). The transform desyncs the `NSView`'s tracking
    /// geometry from where it's drawn, so hover/cursor events stop landing.
    /// Animate a sibling/background layer instead.
    func pointerButton(
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        action: @escaping () -> Void
    ) -> some View {
        overlay(
            PointerControlOverlay(onHoverChange: onHoverChange, action: action)
        )
    }
}

private struct PointerControlOverlay: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onHoverChange = onHoverChange
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackingView else { return }
        view.onHoverChange = onHoverChange
        view.action = action
    }

    final class TrackingView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        var action: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            // Explicit bounds rect rather than `.inVisibleRect`: a
            // SwiftUI-hosted NSView reports an empty visibleRect here, so
            // an `.inVisibleRect` area would track nothing.
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .mouseEnteredAndExited,
                          .activeInActiveApp],
                owner: self
            ))
        }

        // The decisive hook: AppKit calls this as its final cursor
        // decision for the topmost view under the pointer, so setting
        // here is not overridden afterward.
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

        // Act on mouse-up inside the bounds (standard button semantics:
        // a press that drags off and releases outside does not fire).
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { action?() }
        }
    }
}
