import SwiftUI

/// One calendar event in the today sidebar: start time and title. Past events
/// (already ended) render dimmed but remain for context.
struct CalendarItemRow: View {
    let row: TodayCalendarRow
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeText)
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(row.item.title)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .opacity(row.isPast ? 0.45 : 1.0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Start time in local time, honoring the 12/24-hour preference (same
    /// format source the clock uses).
    private var timeText: String {
        guard let start = TodayCalendar.startAt(row.item) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = settings.settings.timeFormat.dateFormat
        return formatter.string(from: start)
    }
}
