import SwiftUI
import AppKit

/// In-window standing-desk status, shown below the clock. Derives its
/// content from `DeskSettings.timerPhase(at:)`, so it tracks the
/// minute tick and any settings change automatically. Always visible
/// when the desk timer is enabled — visual is never schedule-gated.
struct DeskStatusView: View {
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared

    private var phase: DeskTimerPhase {
        settings.settings.desk.timerPhase(at: clock.currentTime)
    }

    var body: some View {
        Group {
            switch phase {
            case .inactive:
                EmptyView()

            case .counting(let remaining, let position):
                DeskCountingRow(remaining: remaining, position: position)

            case .nudge(let from):
                DeskNudgeBanner(target: from.opposite)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

/// SF Symbol representing a desk posture. Shared by the counting row and
/// the nudge banner so the seated/standing icon stays consistent.
private func deskGlyph(for position: DeskPosition) -> String {
    position == .sitting ? "figure.seated.side" : "figure.stand"
}

/// Countdown summary, e.g. "Sitting · switch to standing in 12 min".
private func deskCountingText(
    remaining: TimeInterval,
    position: DeskPosition
) -> String {
    let mins = max(1, Int(ceil(remaining / 60)))
    return "\(position.displayName) · switch to "
        + "\(position.opposite.displayName.lowercased()) in \(mins) min"
}

/// The counting (not-yet-due) state: a posture glyph + countdown, with a
/// secondary "Switch now" button for an early manual switch. The button
/// mirrors the nudge's acknowledge control — a capsule that brightens on
/// hover and shows the pointing-hand cursor — but tuned for this muted
/// row: a faint `primary`-tinted fill that adapts to light and dark.
private struct DeskCountingRow: View {
    let remaining: TimeInterval
    let position: DeskPosition

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deskGlyph(for: position))
            Text(deskCountingText(remaining: remaining, position: position))

            Text("Switch now")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Color.primary.opacity(isHovering ? 0.16 : 0.08),
                    in: Capsule()
                )
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .pointerButton(onHoverChange: { isHovering = $0 }) {
                    DeskService.shared.acknowledgeSwitch()
                }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }
}

/// The sticky switch nudge, rendered as a self-contained accent pill: a
/// posture glyph + the prompt, with the acknowledge action inline as a
/// subordinate translucent-white capsule. The pill breathes (a subtle
/// scale + brightness throb + accent glow) to stay noticeable until
/// acknowledged; the inner button brightens and shows a pointing-hand
/// cursor on hover.
///
/// Colors are theme-independent on purpose — the pill paints its own
/// fixed accent background with white foreground, so it reads identically
/// in light and dark mode regardless of the window behind it. Motion is
/// gated on Reduce Motion: when that's on, the pill holds a steady accent
/// glow instead of animating.
private struct DeskNudgeBanner: View {
    /// The posture to switch *into* — drives both the glyph and the verb.
    let target: DeskPosition

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: deskGlyph(for: target))
                Text("Time to \(target.verb)")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)

            Text("I've switched")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    .white.opacity(isHovering ? 0.38 : 0.22),
                    in: Capsule()
                )
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .pointerButton(onHoverChange: { isHovering = $0 }) {
                    DeskService.shared.acknowledgeSwitch()
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(pill)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }

    /// The pulsing pill: an accent capsule whose fill brightness throbs,
    /// that breathes with a subtle scale, and carries an accent glow. Kept
    /// as the *background* of the content rather than a wrapper around it,
    /// so the scale transform stays off the interactive layer — a transform
    /// on the pointerButton overlay desyncs its AppKit mouse tracking from
    /// where it's drawn, which kills hover + cursor.
    private var pill: some View {
        Capsule()
            .fill(Color.accentColor.opacity(pillFillOpacity))
            .scaleEffect(reduceMotion ? 1.0 : (pulse ? 1.03 : 1.0))
            .shadow(color: glowColor, radius: glowRadius)
    }

    private var pillFillOpacity: Double {
        if reduceMotion { return 1.0 }
        return pulse ? 1.0 : 0.72
    }

    /// Accent glow around the pill — animated between dim and bright while
    /// pulsing, or a steady mid-strength glow when Reduce Motion is on so
    /// the cue still stands out without movement.
    private var glowColor: Color {
        if reduceMotion { return Color.accentColor.opacity(0.5) }
        return Color.accentColor.opacity(pulse ? 0.7 : 0.2)
    }

    private var glowRadius: CGFloat {
        if reduceMotion { return 14 }
        return pulse ? 20 : 6
    }
}
