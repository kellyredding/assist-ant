import SwiftUI
import AppKit

/// Fixed point size of the floating drag chip.
private let dragPreviewSize = CGSize(width: 300, height: 40)

/// The drag grip on an actionable row's leading edge. An AppKit view owns the
/// cursor (reliable open/closed hand) and the drag (`NSDraggingSource`). Two
/// things drove this design:
///   - SwiftUI's `.onDrag` gave no reliable cursor and no drag-end callback, so
///     a cancelled drag left placeholders stranded. `NSDraggingSource` gives us
///     `endedAt` (fires on drop OR cancel) to clear the session.
///   - The system-rendered drag image shrinks once the session takes over — a
///     known, undocumented quirk. So we hand the session an INVISIBLE image and
///     render the chip ourselves in a floating panel that follows the cursor
///     (`draggingSession(_:movedTo:)`). A live view can't be rescaled by the
///     session.
/// The drop side stays SwiftUI (`ItemDropDelegate`), reading the payload from
/// `ItemDragSession`.
struct ActionableDragHandle: View {
    let item: Item
    let payload: ItemDragSession.Payload
    let isRowHovering: Bool

    /// The grip column width — sized so the bars clear the 3pt focus-bar overlay
    /// and the checkbox/caret below line up with it (see ActionableListSection's
    /// matching header inset).
    static let columnWidth: CGFloat = 22

    var body: some View {
        DragGrip(item: item, payload: payload, isRowHovering: isRowHovering)
            .frame(width: Self.columnWidth, height: 20)
            .accessibilityLabel("Reorder")
    }
}

/// SwiftUI ↔ AppKit bridge for the grip.
private struct DragGrip: NSViewRepresentable {
    let item: Item
    let payload: ItemDragSession.Payload
    let isRowHovering: Bool

    func makeNSView(context: Context) -> DragGripNSView { DragGripNSView() }

    func updateNSView(_ view: DragGripNSView, context: Context) {
        view.item = item
        view.payload = payload
        view.isRowHovering = isRowHovering
        // Hidden tabs stay mounted (opacity 0 + hit-testing off), but an
        // NSTrackingArea fires regardless of that, so an occluded grip would set
        // its cursor through the pane on top. Gate it on the surface being
        // enabled (ContentView disables inactive panes), like `pointerButton`.
        view.isActive = context.environment.isEnabled
    }
}

/// A compact, lifted row chip (badge + title). Hosted in a floating panel that
/// follows the cursor — never handed to the drag session — so nothing rescales
/// it. Concrete theme-matched background so it reads in dark mode.
private struct DragRowPreview: View {
    let item: Item
    let isDark: Bool
    var body: some View {
        HStack(spacing: 8) {
            KindBadge(item: item)
            Text(item.title)
                .font(.callout).fontWeight(.semibold)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: dragPreviewSize.width, height: dragPreviewSize.height, alignment: .leading)
        .background(isDark ? Color(white: 0.16) : Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isDark ? 0.18 : 0.12))
        )
    }
}

/// The single floating panel that renders the drag chip at the cursor. Mirrors
/// ItemTooltipController's borderless, non-activating, click-through panel.
@MainActor
private final class DragPreviewPanel {
    static let shared = DragPreviewPanel()
    private var panel: NSPanel?

    func show(item: Item, isDark: Bool, at screenPoint: CGPoint, appearance: NSAppearance?) {
        let host = NSHostingView(rootView:
            DragRowPreview(item: item, isDark: isDark)
                .environment(\.colorScheme, isDark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: dragPreviewSize)

        let p = panel ?? makePanel()
        p.appearance = appearance
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

    /// Place the chip just to the right of the cursor, vertically centered on it.
    /// Screen coords are y-up.
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
/// with an invisible image (the visible chip is `DragPreviewPanel`).
final class DragGripNSView: NSView, NSDraggingSource {
    var item: Item?
    var payload: ItemDragSession.Payload?
    var isRowHovering = false {
        didSet { if isRowHovering != oldValue { needsDisplay = true } }
    }

    private var tracking: NSTrackingArea?
    private var isDragging = false
    /// True only while this grip's surface is the active, interactive one. When
    /// false (its tab is hidden behind another, or covered by the reader), the
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

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

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
        guard let payload else { return }
        // A plain-text pasteboard item makes the drag valid for the SwiftUI drop
        // targets (registered for .text); the real payload is read from
        // ItemDragSession. The dragging image is INVISIBLE — the visible chip is
        // the floating DragPreviewPanel, so the session can't rescale it.
        let pbItem = NSPasteboardItem()
        pbItem.setString(payload.id, forType: .string)
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
        if let payload {
            MainActor.assumeIsolated { ItemDragSession.shared.begin(payload) }
        }
        if let item {
            MainActor.assumeIsolated {
                DragPreviewPanel.shared.show(
                    item: item, isDark: isDarkAppearance,
                    at: screenPoint, appearance: window?.effectiveAppearance)
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { DragPreviewPanel.shared.move(to: screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        needsDisplay = true
        MainActor.assumeIsolated {
            // Clear the session on every end — drop OR cancel — so placeholders
            // never linger; and tear down the floating chip.
            ItemDragSession.shared.end()
            DragPreviewPanel.shared.hide()
        }
        if let window,
           bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
