import SwiftUI
import AppKit

/// A zero-size probe placed *inside* a SwiftUI `ScrollView`'s content. On mount
/// it walks up to the enclosing `NSScrollView` SwiftUI built and enrolls it with
/// `AutoScrollController` for as long as it's on screen, so drag-time edge
/// auto-scroll can find and drive that list. Must live inside the scroll content:
/// attached to the `ScrollView` itself, `enclosingScrollView` would resolve to a
/// parent (or nil), not this list's scroll view.
struct AutoScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // A non-selected right-pane tab is `.disabled()` by `tabPane`, which
        // propagates `isEnabled = false` here even though the probe sits deep in
        // the pane's ScrollView background. Gate registration on it so only the
        // visible list (and the always-enabled Today list) is ever enrolled —
        // the hidden tabs stay mounted in the ZStack and overlap this list's
        // frame, so without the gate the controller can't tell which list the
        // cursor is actually over and scrolls the wrong one (or none).
        nsView.setActive(context.environment.isEnabled)
    }

    final class ProbeView: NSView {
        private var isActive = true
        private weak var registered: NSScrollView?

        func setActive(_ active: Bool) {
            isActive = active
            syncRegistration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Resolve after SwiftUI finishes assembling the NSScrollView; doing
            // it synchronously here can miss it on first mount.
            DispatchQueue.main.async { [weak self] in self?.syncRegistration() }
        }

        // Pane removal: drop the registration as the window clears.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { unregister() }
        }

        /// Enroll this list only while it is the active surface (its pane
        /// enabled) and on screen; otherwise drop it. Idempotent — safe to call
        /// from every `updateNSView` and on every window / active change.
        private func syncRegistration() {
            guard isActive, window != nil, let scrollView = enclosingScrollView
            else { unregister(); return }
            guard registered !== scrollView else { return }
            unregister()
            AutoScrollController.shared.register(scrollView)
            registered = scrollView
        }

        private func unregister() {
            guard let registered else { return }
            AutoScrollController.shared.unregister(registered)
            self.registered = nil
        }
    }
}

extension View {
    /// Attach inside a `ScrollView`'s content to enroll its `NSScrollView` in
    /// drag-time edge auto-scroll. A zero-size, non-interactive background probe.
    func autoScrollDuringDrag() -> some View {
        background(AutoScrollProbe().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
