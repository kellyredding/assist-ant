import SwiftUI

/// Per-day editor for an `AnnouncementHours`. Lists each day in fixed order
/// (Sunday first), letting each row decide whether it's collapsed (just
/// the checkbox) or expanded (showing its time ranges). Bound to the
/// shared `AppSettings.announcementHours` from the Announcements tab.
///
/// Renders as a bare column with no background of its own — it's the sole
/// occupant of the Announcement Hours `SettingsCard`, which already supplies
/// the box chrome and content padding. Carrying its own padded box here would
/// nest a box-in-box and push the day checkboxes inboard of the card's
/// other controls (e.g. the Mute toggle).
struct AnnouncementHoursEditor: View {
    @Binding var announcementHours: AnnouncementHours

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Weekday.displayOrder, id: \.self) { day in
                AnnouncementHoursDayRow(
                    day: day,
                    dayHours: binding(for: day)
                )
            }
        }
    }

    /// Translates `announcementHours.days[day]` to a Binding<DayHours> for the
    /// row view. Falls back to `.empty` if the dictionary lookup misses,
    /// which it shouldn't because AnnouncementHours.empty initializes every
    /// weekday — but we're being defensive.
    private func binding(for day: Weekday) -> Binding<DayHours> {
        Binding(
            get: { announcementHours.days[day] ?? .empty },
            set: { announcementHours.days[day] = $0 }
        )
    }
}
