import AppKit
import SwiftUI

/// Owns the single floating tooltip panel shown when hovering an index-view row,
/// plus the warm-up / sticky-switch / instant-hide timing and the positioning
/// math. App-wide singleton — only one tooltip is ever on screen.
///
/// Timing (steered with the user):
/// - First show waits a warm-up delay so the tooltip doesn't strobe while the
///   pointer scans rows.
/// - Once shown, moving to an adjacent row swaps the content and repositions
///   immediately (no re-delay, no flicker).
/// - Moving off all rows hides effectively instantly — a near-zero debounce
///   that an adjacent row's hover-enter cancels, so a row→row move never
///   blinks the panel out.
///
/// Positioning (steered with the user): Today rows hang to the right of the
/// row; Schedule + Icebox rows hang to the left. The panel grows toward
/// whichever vertical side has more room, the body wraps to the horizontal room
/// available on its side (so it never clips on the right), and any overflow past
/// the available height clips at the bottom. The panel is always bounded inside
/// the app window.
@MainActor
final class ItemTooltipController {
    static let shared = ItemTooltipController()

    /// Which side of the row the tooltip hangs off of. Today → right (into the
    /// main pane); Schedule / Icebox → left (over the sidebar).
    enum Side { case right, left }

    private var panel: NSPanel?
    /// The row the tooltip currently tracks. Identity-gates hide vs. switch so a
    /// stale hover-exit from the row we just left can't dismiss the tooltip that
    /// an adjacent row's hover-enter has already taken over.
    private var currentAnchor: RowFrameAnchor?
    private var isShowing = false

    private var warmupTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []

    /// Warm-up before the first show. Long enough not to flicker while scanning,
    /// short enough to feel responsive on a deliberate hover.
    private static let warmupDelay: Duration = .milliseconds(450)
    /// Hide debounce. Near-zero, but enough to bridge an exit-then-enter pair
    /// when moving between adjacent rows so the panel doesn't blink.
    private static let hideDebounce: Duration = .milliseconds(50)

    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    /// Max tooltip width as a fraction of the window width, clamped to a
    /// comfortable reading column. Caps the right-hung Today tooltips, which
    /// would otherwise stretch across the full main pane; left-hung tooltips
    /// stay bounded by the sidebar width regardless.
    private static let maxWidthFraction: CGFloat = 0.33
    private static let minMaxWidth: CGFloat = 300
    private static let maxMaxWidth: CGFloat = 420

    private init() {}

    // MARK: - Hover intent

    /// Hover-enter on a row. If a tooltip is already showing, swap its content
    /// and reposition immediately (sticky switch); otherwise arm the warm-up.
    ///
    /// Not gated on the reader: the reader floats only over the right pane
    /// (Icebox / Schedule), whose rows go `.disabled` and stop firing hover
    /// while it's open, so they self-suppress. The Today sidebar is never
    /// covered, so its tooltips must keep working with the reader up — including
    /// in edit mode. The panel floats above the reader regardless.
    func requestShow(_ item: Item, anchor: RowFrameAnchor, side: Side) {
        hideTask?.cancel()
        hideTask = nil

        currentAnchor = anchor
        if isShowing {
            present(item, anchor: anchor, side: side)
            return
        }
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.warmupDelay)
            guard let self, !Task.isCancelled else { return }
            self.isShowing = true
            self.present(item, anchor: anchor, side: side)
        }
    }

    /// Hover-exit from a row. Ignored unless it's the row the tooltip is
    /// tracking (a late exit from an already-superseded row is a no-op). Cancels
    /// a pending warm-up and arms the near-zero hide debounce; an adjacent row's
    /// `requestShow` cancels it before it fires, yielding a seamless switch.
    func requestHide(_ anchor: RowFrameAnchor) {
        guard currentAnchor === anchor else { return }
        warmupTask?.cancel()
        warmupTask = nil
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDebounce)
            guard let self, !Task.isCancelled,
                  self.currentAnchor === anchor else { return }
            self.hideNow()
        }
    }

    /// Tear the tooltip down now and cancel any pending work. Safe to call when
    /// nothing is showing. Used on row unmount (scroll-away), window
    /// resize/move, scroll, and when the reader opens.
    func hideNow() {
        warmupTask?.cancel()
        warmupTask = nil
        hideTask?.cancel()
        hideTask = nil
        isShowing = false
        currentAnchor = nil
        removeWindowObservers()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Presentation

    private func present(_ item: Item, anchor: RowFrameAnchor, side: Side) {
        guard let (window, rowFrame) = anchor.currentWindowAndFrame() else { return }
        let win = window.frame                      // screen coords, y-up
        let gap = Self.gap, margin = Self.margin

        // Horizontal room on the chosen side, capped at a readable maximum so a
        // right-hung tooltip over the wide main pane doesn't sprawl. The cap is
        // ~a third of the window, clamped to a comfortable reading column; the
        // body wraps to the result, so it never clips on the right and a narrow
        // sidebar simply yields a narrower, taller tooltip.
        let room: CGFloat = side == .right
            ? win.maxX - (rowFrame.maxX + gap) - margin
            : (rowFrame.minX - gap) - win.minX - margin
        guard room > 1 else { return }
        let maxWidth = min(max(win.width * Self.maxWidthFraction, Self.minMaxWidth),
                           Self.maxMaxWidth)
        let panelWidth = min(room, maxWidth)

        // Height of the content wrapped to the chosen width.
        let contentHeight = NSHostingView(
            rootView: ItemTooltipContent(item: item)
                .frame(width: panelWidth, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        ).fittingSize.height

        // Vertical: grow toward whichever side has more room. AppKit screen
        // coords are y-up, so the row's top is `rowFrame.maxY` and the window's
        // bottom is `win.minY`.
        let roomDown = rowFrame.maxY - win.minY     // row top → window bottom
        let roomUp = win.maxY - rowFrame.minY       // row bottom → window top
        let growDown = roomDown >= roomUp
        let height = min(contentHeight, growDown ? roomDown : roomUp)

        // Origin (bottom-left). Pin the edge on the chosen side and let the
        // panel extend the other way; bottom overflow past `height` clips.
        let originX = side == .right
            ? rowFrame.maxX + gap
            : (rowFrame.minX - gap) - panelWidth
        let originY = growDown
            ? rowFrame.maxY - height                // top pinned at the row top
            : rowFrame.minY                         // bottom pinned at row bottom
        let frame = clampInside(
            NSRect(x: originX, y: originY, width: panelWidth, height: height),
            within: win
        )

        // Re-host at the final clipped size: top-leading so the leading content
        // always shows, `.clipped()` drops any bottom overflow.
        let content = NSHostingView(
            rootView: ItemTooltipContent(item: item)
                .frame(width: frame.width, height: frame.height,
                       alignment: .topLeading)
                .clipped()
        )
        showPanel(content: content, frame: frame,
                  appearance: window.effectiveAppearance)
        installWindowObservers(for: window)
    }

    /// Create-or-reuse the borderless, non-activating floating panel. Reuse (vs.
    /// recreate) is what makes the sticky adjacent-row switch seamless. The
    /// panel ignores mouse events so it never intercepts the hover that drives
    /// the rows beneath it.
    private func showPanel(content: NSView, frame: NSRect,
                           appearance: NSAppearance?) {
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            p.ignoresMouseEvents = true
            panel = p
        }
        p.appearance = appearance
        p.contentView = content
        p.setFrame(frame, display: true)
        p.orderFront(nil)
    }

    /// Clamp a rect fully inside the window. The math already keeps it within
    /// bounds on the chosen side; this is a safety net against rounding.
    private func clampInside(_ rect: NSRect, within win: NSRect) -> NSRect {
        var f = rect
        if f.maxX > win.maxX { f.origin.x = win.maxX - f.width }
        if f.minX < win.minX { f.origin.x = win.minX }
        if f.maxY > win.maxY { f.origin.y = win.maxY - f.height }
        if f.minY < win.minY { f.origin.y = win.minY }
        return f
    }

    // MARK: - Dismissal observers

    /// The panel's origin is computed once from the row's hover-time frame and
    /// does not follow the window. Hide it on a live resize, a move, or a scroll
    /// so it never strands at stale coordinates; the next hover re-shows it.
    private func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        let names: [(Notification.Name, Any?)] = [
            (NSWindow.willStartLiveResizeNotification, window),
            (NSWindow.didMoveNotification, window),
            // Any scroll view in the app: the tooltip is anchored to a row that
            // has just moved under the pointer.
            (NSScrollView.didLiveScrollNotification, nil),
        ]
        for (name, object) in names {
            let token = center.addObserver(
                forName: name, object: object, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ItemTooltipController.shared.hideNow() }
            }
            windowObservers.append(token)
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObservers { center.removeObserver(token) }
        windowObservers.removeAll()
    }
}
