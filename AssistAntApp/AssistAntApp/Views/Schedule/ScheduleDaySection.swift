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
    /// Drop handling for the agenda's actionable rows + the absent-list slot.
    let dropHandler: ActionableDropHandler
    let isCollapsed: (String) -> Bool
    let onToggle: (String) -> Void

    /// The live drag, so a day can show its absent-list drop placeholder.
    @ObservedObject private var drag = ItemDragSession.shared

    private var isToday: Bool { day.date == CivilDate(now) }
    private var isEmpty: Bool { day.events.isEmpty && day.actionableGroups.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            gutter.frame(width: 44, alignment: .center)
            VStack(alignment: .leading, spacing: 6) {
                if isEmpty {
                    Text("Nothing scheduled")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        // Align with the rows' content margin (caret / checkbox).
                        .padding(.leading, 8)
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
                            context: .schedule,
                            dropHandler: dropHandler,
                            day: day.date
                        )
                    }
                }
                // While dragging a schedule row whose list this day lacks, offer
                // a placeholder so it can drop into that list here — preserving
                // the list name and rescheduling onto this day. Past days accept
                // only resolved items (handled by the drop handler's canDrop).
                if let p = drag.payload, p.surface == .schedule,
                   (day.date >= CivilDate.today || p.isResolved),
                   !day.actionableGroups.contains(where: { $0.listName == p.listName }) {
                    AbsentListDropSlot(listName: p.listName, day: day.date, handler: dropHandler)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var gutter: some View {
        // Centered so the weekday + month sit horizontally centered under the
        // day number (whose 30pt frame leaves room for the today circle).
        VStack(alignment: .center, spacing: 2) {
            // Proportional digits (not monospaced) so the number centers by its
            // real width — a monospaced "1" sits in a full-width cell, which made
            // "14" read right-heavy and cramped in the circle. A slightly larger
            // circle gives the number a touch more breathing room all around.
            Text(dayNumber)
                .font(.title2)
                .foregroundStyle(isToday ? Color.white : .primary)
                .frame(width: 32, height: 32)
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
