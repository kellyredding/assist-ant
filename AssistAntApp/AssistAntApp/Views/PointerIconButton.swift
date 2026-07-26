import SwiftUI

/// An SF Symbol button that brightens on hover and shows the pointing-hand
/// cursor — the icon analog of `CapsuleActionButton`. Built as its own struct
/// on purpose: the `pointerButton` overlay's AppKit cursor tracking only lands
/// reliably when the affordance keeps a stable view identity across parent
/// re-renders (see CapsuleActionButton's note).
///
/// Pass `confirmSystemName` to briefly swap in a confirmation glyph once the
/// action has fired. That is for actions whose effect lands somewhere the
/// button can't show — a click otherwise looks like nothing happened. Same
/// green-check treatment as `CopyButton`; leaving it nil keeps the icon static.
struct PointerIconButton: View {
    let systemName: String
    var help: String = ""
    /// Glyph to flash after `action` fires. Nil disables the confirmation.
    var confirmSystemName: String? = nil
    var confirmColor: Color = .green
    var confirmDuration: TimeInterval = 2
    let action: () -> Void

    @State private var isHovering = false
    @State private var isConfirming = false
    /// Tags the newest flash so a stale revert can't cut short a flash the
    /// user restarted by clicking again mid-confirmation.
    @State private var confirmToken = 0

    var body: some View {
        Image(systemName: isConfirming
            ? (confirmSystemName ?? systemName) : systemName)
            .font(.system(size: 13))
            .foregroundStyle(iconStyle)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0))
            )
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .help(help)
            // pointerButton must be the OUTERMOST modifier so its cursor-
            // tracking overlay stays topmost — applying .help after it
            // shadowed the overlay and dropped the pointing-hand cursor.
            .pointerButton(onHoverChange: { isHovering = $0 }, action: fire)
    }

    /// Green while confirming, otherwise the resting hierarchical primary.
    /// Both branches are wrapped so `foregroundStyle` sees a single type.
    private var iconStyle: AnyShapeStyle {
        isConfirming
            ? AnyShapeStyle(confirmColor)
            : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    /// Run the action, then hold the confirmation glyph for `confirmDuration`.
    /// Re-clicking restarts the window rather than inheriting the old revert.
    private func fire() {
        action()
        guard confirmSystemName != nil else { return }
        confirmToken += 1
        let token = confirmToken
        withAnimation { isConfirming = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmDuration) {
            guard token == confirmToken else { return }
            withAnimation { isConfirming = false }
        }
    }
}
