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
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private weak var registered: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Resolve after SwiftUI finishes assembling the NSScrollView; doing
            // it synchronously here can miss it on first mount.
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                AutoScrollController.shared.register(scrollView)
                self.registered = scrollView
            }
        }

        // Tab switch / pane removal: drop the registration as the window clears.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let registered {
                AutoScrollController.shared.unregister(registered)
                self.registered = nil
            }
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
