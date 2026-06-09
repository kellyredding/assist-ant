import SwiftUI

/// One day in the agenda: a left gutter (day number / weekday / month, today
/// circled) and the day's events — or a muted "no events" line when empty.
struct ScheduleDaySection: View {
    let day: AgendaDay
    let now: Date
    /// Invoked when an event row is tapped, to open it in the reader.
    let onOpen: (Item) -> Void

    private var isToday: Bool { day.date == CivilDate(now) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            gutter.frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if day.items.isEmpty {
                    Text("No events")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(day.items, id: \.id) { item in
                        CalendarEventRow(
                            item: item,
                            isPast: ScheduleAgenda.isPast(item, now: now),
                            onTap: { onOpen(item) }
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var gutter: some View {
        // Centered so the weekday + month sit horizontally centered under the
        // day number (whose 30pt frame leaves room for the today circle).
        VStack(alignment: .center, spacing: 2) {
            Text(dayNumber)
                .font(.title2).monospacedDigit()
                .foregroundStyle(isToday ? Color.white : .primary)
                .frame(width: 30, height: 30)
                .background(isToday ? Circle().fill(Color.accentColor) : nil)
            Text(weekday).font(.caption).foregroundStyle(.secondary)
            Text(month).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var dayNumber: String { String(day.date.day) }

    private func formatted(_ fmt: String) -> String {
        let f = DateFormatter()
        f.dateFormat = fmt
        return f.string(from: day.date.noon)
    }

    private var weekday: String { formatted("EEE").uppercased() }   // MON
    private var month: String { formatted("MMM").uppercased() }     // JUN
}
