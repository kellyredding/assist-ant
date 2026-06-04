import SwiftUI
import AppKit

/// Sizing constants for the resizable left sidebar. The sidebar width is a
/// fraction of the window width — stored as a fraction so the ratio holds
/// across window resizes and display moves — clamped to
/// [minFraction, maxFraction]. The clock scales its fonts to fit the
/// resulting width (see `ClockMetrics` in ClockView).
enum SidebarMetrics {
    /// Narrowest the sidebar may be, as a fraction of the window width.
    static let minFraction: CGFloat = 0.25

    /// Widest the sidebar may be, as a fraction of the window width.
    static let maxFraction: CGFloat = 0.50

    /// Sidebar fraction on first launch (no persisted value yet).
    static let defaultFraction: CGFloat = 0.25

    /// Midpoint of the band. The titlebar toggle snaps to the opposite
    /// extreme of whichever side of this the current fraction is on.
    static var toggleThreshold: CGFloat {
        (minFraction + maxFraction) / 2
    }
}

/// NSViewRepresentable wrapper for smooth, mouse-tracked sidebar resizing.
/// Uses AppKit's direct mouse events rather than SwiftUI's DragGesture for
/// frame-accurate dragging. The clamp bounds are passed in live (the
/// window-relative 25% / 50% widths), so a drag stays within the band.
struct SidebarResizeHandle: NSViewRepresentable {
    let currentWidth: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onDragEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ResizeHandleNSView) {
        view.currentWidth = currentWidth
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.onWidthChange = onWidthChange
        view.onDragEnd = onDragEnd
    }
}

/// AppKit NSView that handles mouse events directly for smooth resize
/// dragging. The view is transparent — SwiftUI draws the visible separator
/// line; this view only owns the cursor and the drag math. The sidebar is
/// always on the left, so dragging right increases the width.
final class ResizeHandleNSView: NSView {
    var currentWidth: CGFloat = 0
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    var onWidthChange: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?

    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isDragging {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartX = NSEvent.mouseLocation.x
        dragStartWidth = currentWidth
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        NSCursor.closedHand.set()  // Reinforce cursor during drag.
        onWidthChange?(clampedWidth(for: NSEvent.mouseLocation.x))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        // Reset cursor; the tracking area re-applies the resize cursor if the
        // pointer is still hovering the handle.
        NSCursor.arrow.set()
        onDragEnd?(clampedWidth(for: NSEvent.mouseLocation.x))
    }

    /// Width for the current pointer X, clamped to the live [min, max] band.
    /// Sidebar is left-anchored, so a rightward drag widens it.
    private func clampedWidth(for pointerX: CGFloat) -> CGFloat {
        let delta = pointerX - dragStartX
        let proposed = dragStartWidth + delta
        return min(max(proposed, minWidth), maxWidth)
    }
}
