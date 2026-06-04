import SwiftUI

/// Drives the adaptive font scaling of the clock display. Every element is
/// `base × scale`, where `scale = sidebarWidth / referenceWidth`, capped at
/// `maxScale` with no lower floor. `referenceWidth` is the width at which the
/// clock fills the column at its base sizes: below it everything scales down
/// (still filling); at/above it the scale caps at 1.0, so the clock holds its
/// base size and the extra width becomes centered padding. Tuned by eye.
enum ClockMetrics {
    static let referenceWidth: CGFloat = 500
    static let maxScale: CGFloat = 1.0

    static func scale(forWidth width: CGFloat) -> CGFloat {
        min(width / referenceWidth, maxScale)
    }
}

/// Big digital clock at the center of the main window. Date line above,
/// clock in the middle, timezone label below. Pulls the current time from
/// ClockService and the format preference from SettingsManager. Re-renders
/// when either source changes, so toggling 12-hour / 24-hour in Settings
/// updates the display in the same frame.
///
/// When announcements are muted, a status row renders below the timezone
/// in system orange — matching the corner `AnnounceStatusButton`'s
/// muted-state color so the two surfaces read as one connected
/// indicator. For a manual mute the row carries an inline "Unmute now"
/// button. The row fades in/out as the mute toggles.
struct ClockView: View {
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var mic = MicActivityService.shared

    /// Live icon state — drives whether (and how) the muted status row
    /// renders. Reuses the same state machine the inline
    /// `AnnounceStatusButton` consults so the two surfaces always agree
    /// on whether mute is active and why.
    private var iconState: AnnouncementIconState {
        settings.settings.iconState(
            at: clock.currentTime,
            micInUse: mic.isMicInUse
        )
    }

    /// Status row text under the timezone when muted, or nil when not
    /// muted. Each mute names its reason.
    private var mutedStatusText: String? {
        switch iconState {
        case .mutedByAway:
            return "Muted while away from desk"
        case .mutedByMic:
            return "Muted while microphone in use"
        case .mutedManually:
            return "Muted"
        case .disabled, .scheduled, .active:
            return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let scale = ClockMetrics.scale(forWidth: geo.size.width)
            VStack(spacing: 12 * scale) {
                Text(formattedDate)
                    .font(.system(size: 24 * scale, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                // Time + announcement status icon as a centered unit. The
                // icon sits inline after the time, sized as a visual peer
                // to the clock, so the [time + icon] group centers together
                // rather than the icon floating in a window corner.
                HStack(spacing: 12 * scale) {
                    Text(formattedTime)
                        .font(.system(size: 80 * scale, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    AnnounceStatusButton(scale: scale)
                }
                Text(timezoneName)
                    .font(.system(size: 15 * scale))
                    .foregroundStyle(.secondary)

                // Standing-desk status (countdown / switch nudge). Renders
                // nothing when the desk timer is disabled or unstarted, so
                // it's inert for users who never enable it. Scales with the
                // clock.
                DeskStatusView(scale: scale)

                // Muted status row — renders last, for either mute reason,
                // with text naming the reason. System orange auto-adapts to
                // light/dark; matches the inline AnnounceStatusButton's
                // muted icon color so the two read as one connected
                // indicator. The fade comes from the parent VStack's
                // `.animation(value: iconState)` paired with this view's
                // `.transition(.opacity)`.
                if let mutedStatusText {
                    MutedStatusRow(
                        text: mutedStatusText,
                        showsUnmute: iconState == .mutedManually,
                        scale: scale
                    )
                    .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(4 * scale)
            .animation(.easeInOut(duration: 0.25), value: iconState)
        }
    }

    /// Full weekday, full month name, day of month, and year. Renders as
    /// e.g. "Tuesday, May 27, 2026" in en_US. ClockService ticks every
    /// minute, so the date naturally rolls over at midnight when the
    /// 12:00 AM tick fires.
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: clock.currentTime)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = settings.settings.timeFormat.dateFormat
        return formatter.string(from: clock.currentTime)
    }

    /// Long localized timezone name, automatically choosing the Daylight or
    /// Standard variant based on whether DST is currently active. So during
    /// summer in the Pacific zone the label reads "Pacific Daylight Time";
    /// the rest of the year it reads "Pacific Standard Time".
    private var timezoneName: String {
        let tz = TimeZone.current
        let isDST = tz.isDaylightSavingTime(for: clock.currentTime)
        let style: NSTimeZone.NameStyle = isDST ? .daylightSaving : .standard
        return tz.localizedName(for: style, locale: .current)
            ?? tz.identifier
    }
}

/// The muted status row under the clock: why announcements are silenced,
/// in system orange. For a manual mute it also carries an inline "Unmute
/// now" button (clicking the speaker icon unmutes too — this is a second
/// way to clear it). The button matches the desk row's secondary capsule
/// (brightens on hover, pointing-hand cursor).
private struct MutedStatusRow: View {
    let text: String
    let showsUnmute: Bool
    let scale: CGFloat

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10 * scale) {
            Text(text)
                .font(.system(size: 16 * scale))
                .foregroundStyle(.orange)

            if showsUnmute {
                Text("Unmute now")
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
                        MuteController.unmute()
                    }
            }
        }
    }
}
