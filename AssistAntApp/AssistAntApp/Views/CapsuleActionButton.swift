import SwiftUI

/// A pill-shaped text button that brightens on hover and shows the
/// pointing-hand cursor. The shared affordance for the clock's secondary
/// actions (Switch now, Away from desk, I'm back, Unmute now, …).
///
/// Built as a dedicated `View` with its own hover state on purpose. The
/// `pointerButton` overlay's AppKit cursor tracking only lands when the
/// affordance owns a stable view identity: inlining the same modifiers in
/// a parent that re-renders left the overlay no longer the topmost hit
/// view, so hover still highlighted the pill but the pointing-hand cursor
/// never showed. Giving each button its own struct (as the working
/// "Away from desk" control already did) keeps the overlay topmost.
struct CapsuleActionButton: View {
    let title: String
    var onAccent: Bool = false
    var scale: CGFloat = 1
    /// Compact sizing for inline-in-row use: the label matches a `.callout`
    /// body row (size + weight) and the capsule is shorter, so a hovered row
    /// doesn't grow vertically. Default keeps the original 14pt-medium pill.
    var compact: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(title)
            .font(compact ? .callout : .system(size: 14 * scale, weight: .medium))
            .foregroundStyle(labelStyle)
            .padding(.horizontal, (onAccent ? 12 : 10) * scale)
            .padding(.vertical, (compact ? 2 : (onAccent ? 5 : 3)) * scale)
            .background(fillStyle, in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .pointerButton(onHoverChange: { isHovering = $0 }, action: action)
    }

    private var labelStyle: AnyShapeStyle {
        onAccent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary)
    }

    private var fillStyle: AnyShapeStyle {
        if onAccent {
            return AnyShapeStyle(Color.white.opacity(isHovering ? 0.38 : 0.22))
        }
        return AnyShapeStyle(Color.primary.opacity(isHovering ? 0.16 : 0.08))
    }
}
