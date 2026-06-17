import AppKit

/// Drives edge auto-scroll during an in-flight row drag. A shared singleton
/// (like the drag sessions) so the payload-agnostic drag grip can feed it the
/// cursor position without knowing which list is under the pointer: every
/// scrollable index list registers its `NSScrollView` here, and on each drag
/// move the controller hit-tests the cursor against the registered views, picks
/// the one whose top/bottom hot zone the cursor sits in, and runs a display link
/// that nudges that clip view until the cursor leaves the zone or the drag ends.
///
/// Why AppKit and not a SwiftUI `ScrollViewReader`: `scrollTo(id:)` jumps to a
/// row, it can't scroll by a continuous delta; and drag-move callbacks stop
/// firing when the cursor parks in the zone, so a self-clocked driver is needed
/// to keep scrolling a stationary cursor.
@MainActor
final class AutoScrollController {
    static let shared = AutoScrollController()

    // Tuning — one place to adjust the feel.
    /// Band depth at each edge, in points: the cursor must be within this far of
    /// the top/bottom of the visible area to engage.
    private let hotZone: CGFloat = 36
    /// Peak scroll speed, points/second, reached at the very edge.
    private let maxSpeed: CGFloat = 900

    /// Live scroll views, enrolled by the probe mounted in each list. Weak so a
    /// torn-down pane drops out without manual bookkeeping races.
    private let registered = NSHashTable<NSScrollView>.weakObjects()

    /// The view to scroll this frame and the signed velocity (points/second;
    /// positive scrolls toward the content end / downward in flipped coords).
    private weak var target: NSScrollView?
    private var velocity: CGFloat = 0

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func register(_ scrollView: NSScrollView) { registered.add(scrollView) }
    func unregister(_ scrollView: NSScrollView) { registered.remove(scrollView) }

    /// Called from the drag grip on every move with the cursor's screen point.
    /// Resolves the hovered scroll view + hot-zone velocity and keeps the link
    /// running for the duration of the drag (idle ticks are no-ops).
    func update(at screenPoint: NSPoint) {
        if let (scrollView, v) = resolve(screenPoint) {
            target = scrollView
            velocity = v
            ensureLink(on: scrollView)
        } else {
            // Inside no zone (or pinned at a scroll limit): idle until the cursor
            // re-enters a zone or the drag ends.
            velocity = 0
        }
    }

    /// Drag ended (drop or cancel) — halt and clear.
    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        target = nil
        velocity = 0
    }

    // MARK: - Resolve

    /// The scroll view under `screenPoint` and the signed velocity its hot zone
    /// implies, or nil when the cursor is in no zone or the view can't scroll
    /// further that direction. Screen coords are y-up/global; convert through the
    /// window to the clip view's own (flipped) space.
    private func resolve(_ screenPoint: NSPoint) -> (NSScrollView, CGFloat)? {
        for scrollView in registered.allObjects {
            guard let window = scrollView.window else { continue }
            let clip = scrollView.contentView
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let p = clip.convert(windowPoint, from: nil)
            let visible = clip.bounds
            guard visible.contains(p) else { continue }

            let distTop = p.y - visible.minY
            let distBottom = visible.maxY - p.y

            if distTop < hotZone {
                let v = -speed(forDepth: (hotZone - distTop) / hotZone)  // up
                return canScroll(scrollView, by: v) ? (scrollView, v) : nil
            }
            if distBottom < hotZone {
                let v = speed(forDepth: (hotZone - distBottom) / hotZone) // down
                return canScroll(scrollView, by: v) ? (scrollView, v) : nil
            }
            return nil   // inside this view, but not in a zone
        }
        return nil
    }

    /// Quadratic ramp: slow near the inner edge of the band for fine placement,
    /// accelerating into the very edge for fast long hauls.
    private func speed(forDepth depth: CGFloat) -> CGFloat {
        let d = max(0, min(1, depth))
        return maxSpeed * d * d
    }

    // MARK: - Display link

    private func ensureLink(on view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        // .common so the link keeps firing inside the drag's modal
        // event-tracking run-loop mode — in .default it would be starved for the
        // whole drag and auto-scroll would silently never run.
        l.add(to: .main, forMode: .common)
        lastTimestamp = 0
        link = l
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let target, velocity != 0 else { return }
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? (1.0 / 60.0) : (now - lastTimestamp)
        lastTimestamp = now
        scroll(target, by: velocity * CGFloat(dt))
    }

    // MARK: - Scroll math

    private func canScroll(_ scrollView: NSScrollView, by delta: CGFloat) -> Bool {
        guard let doc = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let maxY = max(0, doc.bounds.height - clip.bounds.height)
        let y = clip.bounds.origin.y
        if delta < 0 { return y > 0 }
        if delta > 0 { return y < maxY }
        return false
    }

    private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.bounds.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(maxY, max(0, origin.y + delta))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
