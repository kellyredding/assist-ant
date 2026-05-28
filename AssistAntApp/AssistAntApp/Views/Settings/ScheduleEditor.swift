import SwiftUI

/// Per-day editor for a `WeeklySchedule`. Lists each day in fixed order
/// (Sunday first), letting each row decide whether it's collapsed (just
/// the checkbox) or expanded (showing its time ranges). Bound to the
/// shared `AppSettings.schedule` from the Announcements tab.
///
/// Renders as a bare column with no background of its own — it's the sole
/// occupant of the Schedule `SettingsCard`, which already supplies the
/// box chrome and content padding. Carrying its own padded box here would
/// nest a box-in-box and push the day checkboxes inboard of the card's
/// other controls (e.g. the Mute toggle).
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
