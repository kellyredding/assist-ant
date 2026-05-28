import SwiftUI

/// Big digital clock at the center of the main window. Date line above,
/// clock in the middle, timezone label below. Pulls the current time from
/// ClockService and the format preference from SettingsManager. Re-renders
/// when either source changes, so toggling 12-hour / 24-hour in Settings
/// updates the display in the same frame.
struct ClockView: View {
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(formattedDate)
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
            Text(formattedTime)
                .font(.system(size: 96, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(timezoneName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
