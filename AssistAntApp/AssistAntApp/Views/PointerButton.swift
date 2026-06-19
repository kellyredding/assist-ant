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
        view.isActive = context.environment.isEnabled
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackingView else { return }
        view.onHoverChange = onHoverChange
        view.action = action
        // Mirror SwiftUI's `.disabled(...)`: an occluded affordance (e.g. a row
        // behind an open reader) goes inactive so it stops tracking the cursor.
        view.isActive = context.environment.isEnabled
    }

    final class TrackingView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        var action: (() -> Void)?

        /// Mirrors SwiftUI's `isEnabled` environment. When inactive the view
        /// installs no tracking areas and ignores clicks — so an affordance
        /// that is occluded by a sibling (a row behind an open reader) does not
        /// keep firing the hand cursor / hover through its tracking geometry.
        var isActive: Bool = true {
            didSet {
                guard isActive != oldValue else { return }
                // This is assigned from updateNSView (a SwiftUI update pass),
                // so defer the tracking rebuild / hover clear off that pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateTrackingAreas()
                    if !self.isActive { self.onHoverChange?(false) }
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            guard isActive else { return }
            // Explicit bounds rect rather than `.inVisibleRect`: a
            // SwiftUI-hosted NSView reports an empty visibleRect here, so an
            // `.inVisibleRect` area would track nothing. `.enabledDuringMouseDrag`
            // keeps enter/exit symmetric during a drag — otherwise dragging
            // across a list leaves every row it crossed stuck in the hover
            // state, because exit never fires. `.activeAlways` so hover +
            // cursor work even while the app is inactive (pairs with the app's
            // click-through).
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .mouseEnteredAndExited,
                          .enabledDuringMouseDrag, .activeAlways],
                owner: self
            ))
            // This overlay is frequently torn down and recreated *while the
            // pointer is already inside it* (the clock re-renders its
            // affordances on every tick / state change), and no mouseEntered
            // fires for the new instance — so reconcile the hover state here.
            applyHoverCursorIfInside()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyHoverCursorIfInside()
        }

        /// Reconcile hover state to whether the pointer is actually inside.
        /// Sets the hand cursor + hover when inside; clears hover when not —
        /// so a re-layout (scroll, list churn, or a drag) can't leave a stale
        /// highlight on a row the pointer has left. Leaves the cursor alone
        /// when outside, to avoid stomping a sibling overlay's cursor.
        private func applyHoverCursorIfInside() {
            guard isActive, let window = window else {
                onHoverChange?(false)
                return
            }
            let p = convert(window.mouseLocationOutsideOfEventStream,
                            from: nil)
            if bounds.contains(p) {
                NSCursor.pointingHand.set()
                onHoverChange?(true)
            } else {
                onHoverChange?(false)
            }
        }

        // Kept as a bonus: when AppKit does deliver it (this view being the
        // topmost hit view), it re-asserts the hand on every mouse-moved.
        override func cursorUpdate(with event: NSEvent) {
            guard isActive else { return }
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isActive else { return }
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
            guard isActive else { return }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { action?() }
        }
    }
}

// MARK: - Covering-overlay cursor gating

// Two view modifiers that make "an overlay quiets the affordances it covers" a
// structural guarantee instead of a hand-maintained pairing. The tracking areas
// above update the cursor from pointer position alone — ignoring opacity and
// hit-testing — so a covered-but-enabled affordance keeps asserting its cursor
// up through whatever is drawn on top. The only reliable quiet is
// `isEnabled = false`, which these affordances (and the drag grips) honor by
// dropping their tracking areas. Wiring that disable in by hand per overlay or
// per tab is the footgun these modifiers remove: the quiet travels with the
// layer.

extension View {
    /// Stacks `overlay` above this content and disables the content while
    /// `isPresented` is true, so the covered affordances drop their cursor
    /// tracking rather than bleeding it through the overlay. The disable is part
    /// of the construct — an overlay added this way cannot omit it. Compose more
    /// than one by chaining; later layers sit higher and also quiet those below.
    func coveredBy<Overlay: View>(
        _ isPresented: Bool,
        @ViewBuilder _ overlay: () -> Overlay
    ) -> some View {
        ZStack {
            disabled(isPresented)
            if isPresented { overlay() }
        }
    }

    /// One pane in a tab ZStack: visible and interactive only as the selected
    /// tab, layered above the others, and quieted whenever it is not the
    /// frontmost interactive layer — behind another tab, or under `covered` (the
    /// item reader) — so its cursor-tracking affordances can't bleed through what
    /// sits on top. `gateWhenHidden: false` opts a pane out of the
    /// behind-another-tab quiet: the agent terminal tracks its own active state
    /// and carries no bleeding affordances, so it stays enabled while hidden
    /// (disabled only under the reader).
    func tabPane(
        _ tab: MainTab,
        selected: MainTab,
        covered: Bool,
        gateWhenHidden: Bool = true
    ) -> some View {
        let isSelected = selected == tab
        return opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .zIndex(isSelected ? 1 : 0)
            .disabled(covered || (gateWhenHidden && !isSelected))
    }
}
