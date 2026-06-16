import SwiftUI
import AppKit

/// Fixed point size of the floating drag chip both surfaces render.
let dragPreviewSize = CGSize(width: 300, height: 40)

/// A payload-agnostic drag grip — the reusable core behind both the actionable
/// and task row handles. An AppKit view owns the cursor (reliable open/closed
/// hand) and the drag (`NSDraggingSource`), because SwiftUI's `.onDrag` gave no
/// reliable cursor and no drag-end callback (a cancelled drag stranded
/// placeholders), and the system-rendered drag image shrinks once the session
/// takes over. So the session gets an INVISIBLE image and the visible chip is a
/// floating panel that follows the cursor.
///
/// The grip is told only an id (carried on the pasteboard so the SwiftUI drop
/// targets fire) and three lifecycle hooks; each surface wires its own drag
/// session + preview chip through them. The drop side stays SwiftUI.
struct DragGripView: NSViewRepresentable {
    /// The string id placed on the pasteboard — makes the SwiftUI `.onDrop`
    /// (registered for `.text`) fire; the real payload is read from the
    /// surface's own drag session.
    let dragID: String?
    let isRowHovering: Bool
    /// willBeginAt: stamp the session + show the chip. movedTo: move the chip.
    /// endedAt (drop OR cancel): clear the session + hide the chip.
    let onBegin: @MainActor (NSPoint) -> Void
    let onMoved: @MainActor (NSPoint) -> Void
    let onEnd: @MainActor () -> Void

    func makeNSView(context: Context) -> DragGripNSView { DragGripNSView() }

    func updateNSView(_ view: DragGripNSView, context: Context) {
        view.dragID = dragID
        view.isRowHovering = isRowHovering
        view.onBegin = onBegin
        view.onMoved = onMoved
        view.onEnd = onEnd
        // Hidden tabs stay mounted (opacity 0 + hit-testing off), but an
        // NSTrackingArea fires regardless, so an occluded grip would set its
        // cursor through the pane on top. Gate on the surface being enabled.
        view.isActive = context.environment.isEnabled
    }
}

/// The single floating panel that renders a drag chip at the cursor. Mirrors
/// ItemTooltipController's borderless, non-activating, click-through panel.
/// Generic over the chip view so each surface supplies its own.
@MainActor
final class DragPreviewPanel {
    static let shared = DragPreviewPanel()
    private var panel: NSPanel?

    func show<Chip: View>(_ chip: Chip, isDark: Bool, at screenPoint: CGPoint) {
        let host = NSHostingView(rootView:
            chip.environment(\.colorScheme, isDark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: dragPreviewSize)

        let p = panel ?? makePanel()
        p.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        p.contentView = host
        p.setContentSize(dragPreviewSize)
        move(p, to: screenPoint)
        p.orderFront(nil)
        panel = p
    }

    func move(to screenPoint: CGPoint) {
        guard let panel else { return }
        move(panel, to: screenPoint)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Place the chip just to the right of the cursor, vertically centered on
    /// it. Screen coords are y-up.
    private func move(_ panel: NSPanel, to screenPoint: CGPoint) {
        panel.setFrameOrigin(NSPoint(
            x: screenPoint.x + 8,
            y: screenPoint.y - dragPreviewSize.height / 2))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: dragPreviewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.ignoresMouseEvents = true
        return p
    }
}

/// The AppKit grip: draws Galaxy's three-bar glyph, owns the open/closed-hand
/// cursor via a tracking area, and starts/ends the drag as an `NSDraggingSource`
/// with an invisible image (the visible chip is `DragPreviewPanel`). Payload-
/// agnostic: it carries a `dragID` string and three lifecycle closures.
final class DragGripNSView: NSView, NSDraggingSource {
    var dragID: String?
    var onBegin: (@MainActor (NSPoint) -> Void)?
    var onMoved: (@MainActor (NSPoint) -> Void)?
    var onEnd: (@MainActor () -> Void)?
    var isRowHovering = false {
        didSet { if isRowHovering != oldValue { needsDisplay = true } }
    }

    private var tracking: NSTrackingArea?
    private var isDragging = false
    /// True only while this grip's surface is the active, interactive one. When
    /// false (its tab is hidden behind another, or covered by a reader), the
    /// tracking area is removed so the open-hand cursor can't bleed through the
    /// pane on top — `NSTrackingArea` enter/exit ignores SwiftUI opacity and
    /// hit-testing, so a mounted-but-hidden pane would otherwise still set it.
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            // Assigned from a SwiftUI update pass; defer the tracking rebuild.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateTrackingAreas()
                if !self.isActive { self.resetCursorIfInside() }
            }
        }
    }

    override var isFlipped: Bool { true }

    // Galaxy grip metrics: three rounded bars, centered.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let alpha: CGFloat = (isRowHovering || isDragging) ? 1.0 : 0.3
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
        let lineW: CGFloat = 8, lineH: CGFloat = 1.5, gap: CGFloat = 2
        let total = lineH * 3 + gap * 2
        let startY = (bounds.height - total) / 2
        let startX = (bounds.width - lineW) / 2
        for i in 0..<3 {
            let y = startY + CGFloat(i) * (lineH + gap)
            NSBezierPath(
                roundedRect: NSRect(x: startX, y: y, width: lineW, height: lineH),
                xRadius: lineH / 2, yRadius: lineH / 2
            ).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tracking { removeTrackingArea(existing); tracking = nil }
        // No tracking while inactive — that's what stops the cursor bleed.
        guard isActive else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// On going inactive while the pointer is still inside, restore the arrow so
    /// a stale open-hand doesn't strand on the surface now on top.
    private func resetCursorIfInside() {
        guard let window else { return }
        if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if isActive && !isDragging { NSCursor.openHand.set() }
    }
    override func cursorUpdate(with event: NSEvent) {
        if isActive && !isDragging { NSCursor.openHand.set() }
    }
    override func mouseExited(with event: NSEvent) {
        if !isDragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let dragID else { return }
        // A plain-text pasteboard item makes the drag valid for the SwiftUI drop
        // targets (registered for .text); the real payload is read from the
        // surface's drag session. The dragging image is INVISIBLE — the visible
        // chip is the floating DragPreviewPanel, so the session can't rescale it.
        let pbItem = NSPasteboardItem()
        pbItem.setString(dragID, forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
            contents: NSImage(size: NSSize(width: 1, height: 1)))
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isDragging = true
        needsDisplay = true
        NSCursor.closedHand.set()
        MainActor.assumeIsolated { onBegin?(screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { onMoved?(screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        needsDisplay = true
        // Clear the session on every end — drop OR cancel — so placeholders
        // never linger, and tear down the floating chip.
        MainActor.assumeIsolated { onEnd?() }
        if let window,
           bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
