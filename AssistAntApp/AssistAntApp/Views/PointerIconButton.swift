import SwiftUI

/// An SF Symbol button that brightens on hover and shows the pointing-hand
/// cursor — the icon analog of `CapsuleActionButton`. Built as its own struct
/// on purpose: the `pointerButton` overlay's AppKit cursor tracking only lands
/// reliably when the affordance keeps a stable view identity across parent
/// re-renders (see CapsuleActionButton's note).
struct PointerIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0))
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .help(help)
            // pointerButton must be the OUTERMOST modifier so its cursor-
            // tracking overlay stays topmost — applying .help after it
            // shadowed the overlay and dropped the pointing-hand cursor.
            .pointerButton(onHoverChange: { isHovering = $0 }, action: action)
    }
}
