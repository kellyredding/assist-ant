import SwiftUI
import AppKit

/// In-window standing-desk + presence status, shown below the clock.
/// Derives its content from `DeskSettings.timerPhase(at:)`, so it tracks
/// the minute tick and any settings change automatically. The away
/// affordance is always available — even with the desk timer off — because
/// "away" is a global concept that mutes announcements.
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
                // Desk timer off (and not away): still offer the global
                // away affordance so stepping away — and its announcement
                // mute — works without the timer.
                DeskPresenceRow(scale: scale)

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

/// The counting (not-yet-due) state: a posture glyph + countdown, with
/// secondary actions to switch early, step away, or turn the timer off.
/// "Disable timer" is distinct from "Away from desk": away mutes every
/// announcement until you return, whereas disabling stops only the desk
/// timer and leaves clock and calendar announcements running — for when
/// you've left the standing desk but are still working elsewhere. The
/// buttons mirror the nudge's acknowledge control — capsules that brighten
/// on hover and show the pointing-hand cursor — but tuned for this muted
/// row: a faint `primary`-tinted fill that adapts to light and dark.
private struct DeskCountingRow: View {
    let remaining: TimeInterval
    let position: DeskPosition
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 8 * scale) {
                Image(systemName: deskGlyph(for: position))
                Text(deskCountingText(remaining: remaining, position: position))
                    .lineLimit(1)
            }

            HStack(spacing: 8 * scale) {
                CapsuleActionButton(title: "Switch now", scale: scale) {
                    DeskService.shared.acknowledgeSwitch()
                }

                CapsuleActionButton(title: "Away from desk", scale: scale) {
                    DeskService.shared.goAway()
                }

                CapsuleActionButton(title: "Disable timer", scale: scale) {
                    DeskService.shared.setEnabled(false)
                }
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

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: deskGlyph(for: target))
                Text("Time to \(target.verb)")
            }
            .font(.system(size: 16 * scale, weight: .semibold))
            .foregroundStyle(.white)

            HStack(spacing: 8 * scale) {
                CapsuleActionButton(title: "I've switched", onAccent: true,
                                    scale: scale) {
                    DeskService.shared.acknowledgeSwitch()
                }

                CapsuleActionButton(title: "Away from desk", onAccent: true,
                                    scale: scale) {
                    DeskService.shared.goAway()
                }

                CapsuleActionButton(title: "Disable timer", onAccent: true,
                                    scale: scale) {
                    DeskService.shared.setEnabled(false)
                }
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

/// The away state: a calm secondary row (not the alert pill) with an
/// "I'm back at my desk" button that resumes a fresh sit interval. Styled
/// like the counting row — being away is informational, not an alert. Not
/// time-bound, so there's no return time to show.
private struct DeskAwayBanner: View {
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "figure.walk.departure")
            Text("Away from desk")

            CapsuleActionButton(title: "I'm back at my desk", scale: scale) {
                DeskService.shared.returnToDesk()
            }
        }
        .font(.system(size: 16 * scale))
        .foregroundStyle(.secondary)
    }
}

/// Shown when the desk timer is OFF and you're at your desk: a neutral
/// presence row with an "Enable timer" affordance to switch the sit/stand
/// timer back on (starting a fresh interval) plus the global "Away from
/// desk" affordance. Stepping away (and its announcement mute) is a global
/// concept, available even when the standing-desk timer is disabled.
private struct DeskPresenceRow: View {
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "chair.fill")
            Text("At your desk")

            CapsuleActionButton(title: "Away from desk", scale: scale) {
                DeskService.shared.goAway()
            }

            CapsuleActionButton(title: "Enable timer", scale: scale) {
                DeskService.shared.setEnabled(true)
            }
        }
        .font(.system(size: 16 * scale))
        .foregroundStyle(.secondary)
    }
}
