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
/// as one connected indicator. The row fades in/out on mute apply,
/// clear, and natural expiry.
struct ClockView: View {
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared

    /// Live icon state — drives whether the muted status row renders.
    /// Reuses the same state machine the corner `AnnounceStatusButton`
    /// consults so the two surfaces always agree on whether mute is
    /// active.
    private var iconState: AnnouncementIconState {
        settings.settings.announcement.iconState(at: clock.currentTime)
    }

    /// Formatted mute end time ("3:30 PM" / "15:30") for the current
    /// mute window, or nil when no mute is active. Defense in depth —
    /// when `iconState == .muted`, this should always be non-nil.
    private var muteEndDisplay: String? {
        MuteController.currentMuteEndDisplay(
            format: settings.settings.timeFormat,
            now: clock.currentTime
        )
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

            // Muted status row — only renders when state == .muted.
            // System orange auto-adapts to light/dark; matches the
            // inline AnnounceStatusButton's muted icon color so the
            // two read as one connected indicator. The fade comes
            // from the parent VStack's `.animation(value: iconState)`
            // paired with this view's `.transition(.opacity)`.
            if iconState == .muted, let display = muteEndDisplay {
                Text("Muted until \(display)")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

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
