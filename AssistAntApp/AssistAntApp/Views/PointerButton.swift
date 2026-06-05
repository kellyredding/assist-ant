import SwiftUI
import AppKit

extension View {
    /// Makes the view act as a clickable control that shows the
    /// pointing-hand cursor while hovered, and reports hover changes.
    ///
    /// SwiftUI on macOS gives plain buttons no pointer cursor, so the cursor
    /// is driven by an AppKit overlay (`TrackingView`) that owns the click
    /// too, rather than passing clicks through to a button beneath it.
    ///
    /// The cursor is set directly on `mouseEntered` / `mouseExited` — the
    /// reliable hook here, the same one the sidebar resize handle uses.
    /// `cursorUpdate(with:)` is kept as a bonus but is NOT sufficient on its
    /// own: AppKit only delivers it to the *topmost hit view*, and once the
    /// clock is hosted inside the sidebar this overlay often is not topmost
    /// (its hover tracking still fires — so the highlight worked but the
    /// cursor didn't). The clock also re-creates these overlays constantly
    /// (every minute tick / state change), frequently *while the pointer is
    /// already inside one*, so the cursor is re-asserted when the view is
    /// (re)created under the pointer — otherwise a recreate mid-hover drops
    /// the hand cursor.
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
            // SwiftUI-hosted NSView reports an empty visibleRect here, so an
            // `.inVisibleRect` area would track nothing. `.activeAlways` so
            // hover + cursor work even while the app is inactive (pairs with
            // the app's click-through).
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .mouseEnteredAndExited,
                          .activeAlways],
                owner: self
            ))
            // This overlay is frequently torn down and recreated *while the
            // pointer is already inside it* (the clock re-renders its
            // affordances on every tick / state change), and no mouseEntered
            // fires for the new instance — so re-assert the cursor here.
            applyHoverCursorIfInside()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyHoverCursorIfInside()
        }

        /// Set the pointing-hand cursor (and hover state) when the pointer is
        /// currently within this view. Recovers the cursor after a re-create
        /// that happened under the pointer, where no mouseEntered fires.
        private func applyHoverCursorIfInside() {
            guard let window = window else { return }
            let p = convert(window.mouseLocationOutsideOfEventStream,
                            from: nil)
            if bounds.contains(p) {
                NSCursor.pointingHand.set()
                onHoverChange?(true)
            }
        }

        // Kept as a bonus: when AppKit does deliver it (this view being the
        // topmost hit view), it re-asserts the hand on every mouse-moved.
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
            onHoverChange?(false)
        }

        // Act on mouse-up inside the bounds (standard button semantics: a
        // press that drags off and releases outside does not fire).
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { action?() }
        }
    }
}
