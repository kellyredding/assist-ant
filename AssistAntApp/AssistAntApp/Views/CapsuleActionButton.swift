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
    /// Underlines the first (case-insensitive) occurrence of this character in
    /// the label — the mnemonic hint for a keyboard chord. nil = plain label.
    var mnemonic: Character? = nil
    /// When set, the button renders this SF Symbol in place of the title text
    /// (the glyph variant for narrow surfaces like the Today sidebar). `title`
    /// still carries the action's name, surfaced as the hover tooltip.
    var systemImage: String? = nil
    /// Overrides the hover tooltip. Defaults to the title (in glyph mode) or
    /// none — set it to explain a disabled state (e.g. a synced item).
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        label
            .font(compact ? .callout : .system(size: 14 * scale, weight: .medium))
            .foregroundStyle(labelStyle)
            .padding(.horizontal, (onAccent ? 12 : 10) * scale)
            .padding(.vertical, (compact ? 2 : (onAccent ? 5 : 3)) * scale)
            .background(fillStyle, in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .help(help ?? (systemImage != nil ? title : ""))
            .pointerButton(onHoverChange: { isHovering = $0 }, action: action)
    }

    /// The label: the SF Symbol when `systemImage` is set, else the title text —
    /// underlining the first (case-insensitive) occurrence of the mnemonic
    /// character when one is set.
    private var label: Text {
        if let systemImage { return Text(Image(systemName: systemImage)) }
        guard let mnemonic,
              let i = title.firstIndex(where: {
                  $0.lowercased() == String(mnemonic).lowercased()
              })
        else { return Text(title) }
        var attr = AttributedString(title)
        let offset = title.distance(from: title.startIndex, to: i)
        let start = attr.index(attr.startIndex, offsetByCharacters: offset)
        let end = attr.index(start, offsetByCharacters: 1)
        attr[start..<end].underlineStyle = .single
        return Text(attr)
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
