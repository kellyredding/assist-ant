import SwiftUI

/// The Status popover's content: the clock header (date, time + speaker/mute
/// icon, timezone) reused verbatim from the sidebar, then the keyboard-navigable
/// desk controls, then a one-line key hint. Mirrors `CaptureContentView`'s themed
/// rounded container (own background + clip + `preferredColorScheme`, Esc closes).
///
/// The desk controls call `onClose` after firing, so acting on the popover
/// (e.g. confirming a switch) dismisses it and hands focus back to the app you
/// summoned from — the "one keystroke, set it, back to work" path.
struct StatusPopoverContent: View {
    var colorScheme: ColorScheme?
    var onClose: () -> Void

    /// Fixed compact scale for the floating popover: width 420 / reference 500.
    /// Smaller than the sidebar's full-size clock so the panel reads as a
    /// heads-up overlay rather than a second desk clock.
    private static let width: CGFloat = 420
    private var scale: CGFloat { Self.width / ClockMetrics.referenceWidth }

    var body: some View {
        VStack(spacing: 12 * scale) {
            ClockHeaderView(scale: scale)
            DeskControlsView(scale: scale, onAction: onClose)
            Text("arrows to move · space/return to choose · esc to close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(colorScheme)
        .onExitCommand { onClose() }
    }
}
