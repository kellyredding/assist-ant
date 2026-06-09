import SwiftUI

/// One event in the agenda: an aligned time column and the title. Past events
/// (already ended) render dimmed, matching the today sidebar.
struct CalendarEventRow: View {
    let item: Item
    let isPast: Bool
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            timeColumns
            Text(item.title)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .opacity(isPast ? 0.45 : 1.0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Start and end in separate right-aligned columns with the dash between,
    /// so minutes and AM/PM line up vertically across rows and a range of two
    /// two-digit hours never wraps. The end columns are blank when the event
    /// has no end but keep their width, so titles stay aligned regardless.
    private var timeColumns: some View {
        HStack(spacing: 0) {
            Text(timeString(startAt))
                .frame(width: 68, alignment: .trailing)
            Text(endAt != nil ? "–" : "")
                .frame(width: 24, alignment: .center)   // own column, centered
            Text(endAt != nil ? timeString(endAt) : "")
                .frame(width: 68, alignment: .leading)
        }
        .font(.callout).monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var startAt: Date? {
        if case .calendar(let d) = item.typeData { return d.startAt }
        return nil
    }

    private var endAt: Date? {
        if case .calendar(let d) = item.typeData { return d.endAt }
        return nil
    }

    /// `date` in local time, honoring the 12/24-hour preference.
    private func timeString(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = settings.settings.timeFormat.dateFormat
        return f.string(from: date)
    }
}
