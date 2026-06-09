import SwiftUI

/// One day in the announcement-hours editor. Collapsed when disabled (just
/// the checkbox + day name). Expanded when enabled to show the day's time
/// ranges plus an "Add time range" button.
struct AnnouncementHoursDayRow: View {
    let day: Weekday
    @Binding var dayHours: DayHours

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(day.displayName, isOn: enabledBinding)
                .toggleStyle(.checkbox)

            if dayHours.enabled {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach($dayHours.ranges) { $range in
                        TimeRangeRow(
                            range: $range,
                            onDelete: { removeRange(range.id) }
                        )
                    }

                    Button {
                        dayHours.ranges.append(.newWorkdayDefault)
                    } label: {
                        Label(
                            "Add time range",
                            systemImage: "plus.circle"
                        )
                    }
                    .buttonStyle(.borderless)
                    // Indent under the checkbox label.
                    .padding(.leading, 22)
                }
            }
        }
    }

    private func removeRange(_ id: UUID) {
        dayHours.ranges.removeAll { $0.id == id }
    }

    /// Custom enabled-binding that auto-adds a default range the first
    /// time the user checks a previously-empty day. A day re-checked with
    /// existing ranges (e.g. they unchecked it, then changed their mind)
    /// just re-enables without adding another range.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { dayHours.enabled },
            set: { newValue in
                dayHours.enabled = newValue
                if newValue && dayHours.ranges.isEmpty {
                    dayHours.ranges.append(.newWorkdayDefault)
                }
            }
        )
    }
}
