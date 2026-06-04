import SwiftUI
import AppKit

/// In-window standing-desk status, shown below the clock. Derives its
/// content from `DeskSettings.timerPhase(at:)`, so it tracks the
/// minute tick and any settings change automatically. Always visible
/// when the desk timer is enabled — visual is never schedule-gated.
struct DeskStatusView: View {
    /// Scale factor applied to every font, spacing, and padding so the desk
    /// affordances track the adaptively-scaled clock above them. 1 = natural
    /// size.
    var scale: CGFloat = 1

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
                DeskCountingRow(
                    remaining: remaining,
                    position: position,
                    scale: scale
                )

            case .nudge(let from):
                DeskNudgeBanner(target: from.opposite, scale: scale)
                    .transition(.opacity)

            case .away:
                DeskAwayBanner(scale: scale)
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
    let scale: CGFloat

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 8 * scale) {
                Image(systemName: deskGlyph(for: position))
                Text(deskCountingText(remaining: remaining, position: position))
                    .lineLimit(1)
            }

            HStack(spacing: 8 * scale) {
                Text("Switch now")
                    .font(.system(size: 14 * scale, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(
                        Color.primary.opacity(isHovering ? 0.16 : 0.08),
                        in: Capsule()
                    )
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                    .pointerButton(onHoverChange: { isHovering = $0 }) {
                        DeskService.shared.acknowledgeSwitch()
                    }

                AwayButton(onAccent: false, scale: scale)
            }
        }
        .font(.system(size: 16 * scale))
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
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: deskGlyph(for: target))
                Text("Time to \(target.verb)")
            }
            .font(.system(size: 16 * scale, weight: .semibold))
            .foregroundStyle(.white)

            HStack(spacing: 8 * scale) {
                Text("I've switched")
                    .font(.system(size: 14 * scale, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(
                        .white.opacity(isHovering ? 0.38 : 0.22),
                        in: Capsule()
                    )
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                    .pointerButton(onHoverChange: { isHovering = $0 }) {
                        DeskService.shared.acknowledgeSwitch()
                    }

                AwayButton(onAccent: true, scale: scale)
            }
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 10 * scale)
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
        if reduceMotion { return 14 * scale }
        return pulse ? 20 * scale : 6 * scale
    }
}

/// The "Away from desk" button — pauses the timer until the user returns
/// (not time-bound). Sits beside the primary action in both the counting
/// and nudge states, matching that action's capsule: `onAccent` gives the
/// translucent-white treatment for the accent nudge pill vs the
/// primary-tinted one for the plain window row.
private struct AwayButton: View {
    let onAccent: Bool
    let scale: CGFloat
    @State private var isHovering = false

    var body: some View {
        Text("Away from desk")
            .font(.system(size: 14 * scale, weight: .medium))
            .foregroundStyle(labelStyle)
            .padding(.horizontal, (onAccent ? 12 : 10) * scale)
            .padding(.vertical, (onAccent ? 5 : 3) * scale)
            .background(fillStyle, in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .pointerButton(onHoverChange: { isHovering = $0 }) {
                DeskService.shared.goAway()
            }
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

/// The away state: a calm secondary row (not the alert pill) with an
/// "I'm back at my desk" button that resumes a fresh sit interval. Styled
/// like the counting row — being away is informational, not an alert. Not
/// time-bound, so there's no return time to show.
private struct DeskAwayBanner: View {
    let scale: CGFloat
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "figure.walk.departure")
            Text("Away from desk")

            Text("I'm back at my desk")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 3 * scale)
                .background(
                    Color.primary.opacity(isHovering ? 0.16 : 0.08),
                    in: Capsule()
                )
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .pointerButton(onHoverChange: { isHovering = $0 }) {
                    DeskService.shared.returnToDesk()
                }
        }
        .font(.system(size: 16 * scale))
        .foregroundStyle(.secondary)
    }
}
