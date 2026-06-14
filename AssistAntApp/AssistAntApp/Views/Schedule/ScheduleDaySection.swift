import SwiftUI

/// One day in the agenda: a left gutter (day number / weekday / month, today
/// circled) and the day's content — its calendar events (time-sorted) followed
/// by its actionable items as the shared list rows grouped into sublists, or a
/// muted "Nothing scheduled" line when the day is empty.
struct ScheduleDaySection: View {
    let day: AgendaDay
    let now: Date
    /// Invoked when a row is tapped, to open it in the reader.
    let onOpen: (Item) -> Void
    let selection: ActionableSelection
    let actions: ActionableActions
    let isCollapsed: (String) -> Bool
    let onToggle: (String) -> Void

    private var isToday: Bool { day.date == CivilDate(now) }
    private var isEmpty: Bool { day.events.isEmpty && day.actionableGroups.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            gutter.frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if isEmpty {
                    Text("Nothing scheduled")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(day.events, id: \.id) { item in
                        CalendarEventRow(
                            item: item,
                            isPast: ScheduleAgenda.isPast(item, now: now),
                            onTap: { onOpen(item) }
                        )
                    }
                    // A thin rule between the timed events and the day's to-dos.
                    if !day.events.isEmpty && !day.actionableGroups.isEmpty {
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(day.actionableGroups) { group in
                        ActionableListSection(
                            group: group,
                            isCollapsed: isCollapsed(group.id),
                            onToggle: onToggle,
                            selection: selection,
                            actions: actions,
                            onOpen: { item in
                                // Carry focus to the opened row so returning
                                // from the reader leaves it focused.
                                selection.focus(item.id)
                                onOpen(item)
                            },
                            context: .schedule
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
