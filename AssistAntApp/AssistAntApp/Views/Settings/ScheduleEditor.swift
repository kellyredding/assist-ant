import SwiftUI

/// Per-day editor for an AnnouncementSettings.schedule. Lists each day in
/// fixed order (Sunday first), letting each row decide whether it's
/// collapsed (just the checkbox) or expanded (showing its time ranges).
struct ScheduleEditor: View {
    @Binding var schedule: WeeklySchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Weekday.displayOrder, id: \.self) { day in
                ScheduleDayRow(
                    day: day,
                    schedule: binding(for: day)
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    /// Translates `schedule.days[day]` to a Binding<DaySchedule> for the
    /// row view. Falls back to `.empty` if the dictionary lookup misses,
    /// which it shouldn't because WeeklySchedule.empty initializes every
    /// weekday — but we're being defensive.
    private func binding(for day: Weekday) -> Binding<DaySchedule> {
        Binding(
            get: { schedule.days[day] ?? .empty },
            set: { schedule.days[day] = $0 }
        )
    }
}
