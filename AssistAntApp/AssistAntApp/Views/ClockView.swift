import SwiftUI

/// Big digital clock at the center of the main window. Date line above,
/// clock in the middle, timezone label below. Pulls the current time from
/// ClockService and the format preference from SettingsManager. Re-renders
/// when either source changes, so toggling 12-hour / 24-hour in Settings
/// updates the display in the same frame.
///
/// When announcements are muted, a "Muted until …" row renders below
/// the timezone in system orange — matching the corner
/// `AnnounceStatusButton`'s muted-state color so the two surfaces read
/// as one connected indicator. For a timed mute the row carries an
/// inline "Unmute now" button (the speaker icon is non-interactive in
/// that state). The row fades in/out on mute apply, clear, and expiry.
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
    /// muted. Away and mic mutes name their reason; the timed mute shows
    /// its end time.
    private var mutedStatusText: String? {
        switch iconState {
        case .mutedByAway:
            return "Muted while away from desk"
        case .mutedByMic:
            return "Muted while microphone in use"
        case .mutedByTimer:
            let display = MuteController.currentMuteEndDisplay(
                format: settings.settings.timeFormat,
                now: clock.currentTime
            )
            return display.map { "Muted until \($0)" }
        case .disabled, .scheduled, .active:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(formattedDate)
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
            // Time + announcement status icon as a centered unit. The
            // icon sits inline after the time, sized as a visual peer
            // to the clock, so the [time + icon] group centers together
            // rather than the icon floating in a window corner.
            HStack(spacing: 12) {
                Text(formattedTime)
                    .font(.system(size: 96, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                AnnounceStatusButton()
            }
            Text(timezoneName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            // Muted status row — renders for either mute reason, with
            // text naming the reason. System orange auto-adapts to
            // light/dark; matches the inline AnnounceStatusButton's
            // muted icon color so the two read as one connected
            // indicator. The fade comes from the parent VStack's
            // `.animation(value: iconState)` paired with this view's
            // `.transition(.opacity)`.
            if let mutedStatusText {
                MutedStatusRow(
                    text: mutedStatusText,
                    showsUnmute: iconState == .mutedByTimer
                )
                .transition(.opacity)
            }

            // Standing-desk status (countdown / switch nudge). Renders
            // nothing when the desk timer is disabled or unstarted, so
            // it's inert for users who never enable it. Independent of
            // the announcement/mute rows above.
            DeskStatusView()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .animation(.easeInOut(duration: 0.25), value: iconState)
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
/// in system orange. For a timed mute it also carries an inline "Unmute
/// now" button — the speaker icon is non-interactive in that state, so
/// this is where the mute is cleared. The button matches the desk row's
/// secondary capsule (brightens on hover, pointing-hand cursor).
private struct MutedStatusRow: View {
    let text: String
    let showsUnmute: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.orange)

            if showsUnmute {
                Text("Unmute now")
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
                        MuteController.unmute()
                    }
            }
        }
    }
}
