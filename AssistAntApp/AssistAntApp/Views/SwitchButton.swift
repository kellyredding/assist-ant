import SwiftUI

/// A button styled as an on/off switch: a capsule track with a sliding knob,
/// green when on and a neutral gray when off, the track brightening on hover.
/// Built on `.pointerButton`, so it shows the pointing-hand cursor on hover and
/// plugs into the covered-by / tabPane cursor gating — the affordance a native
/// `Toggle(.switch)` can't give on macOS. Click anywhere on the pill toggles it.
///
/// Its own `View` struct on purpose: `.pointerButton`'s AppKit cursor tracking
/// only lands when the affordance owns a stable view identity (see
/// `CapsuleActionButton`). Inlining these modifiers in a re-rendering parent
/// leaves the overlay no longer topmost, so the pointing-hand cursor silently
/// stops showing while the rest still works.
struct SwitchButton: View {
    let isOn: Bool
    let onChange: (Bool) -> Void
    /// Hover tooltip + accessibility label (e.g. "Enable task" / "Disable task").
    var help: String? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 24
    private let knobSize: CGFloat = 18

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .overlay(Capsule().fill(Color.white.opacity(isHovering ? 0.14 : 0)))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
                .frame(width: knobSize, height: knobSize)
                .padding(3)
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(help ?? (isOn ? "On" : "Off"))
        .pointerButton(onHoverChange: { isHovering = $0 }, action: { onChange(!isOn) })
        .accessibilityAddTraits(.isToggle)
        .accessibilityLabel(help ?? "Toggle")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    /// Green when on; a theme-matched neutral gray when off. The knob's position
    /// (and these colors) both carry state, so it stays legible without color.
    private var trackColor: Color {
        if isOn { return .green }
        return scheme == .dark
            ? Color(red: 0.35, green: 0.35, blue: 0.38)
            : Color(red: 0.76, green: 0.76, blue: 0.79)
    }
}
