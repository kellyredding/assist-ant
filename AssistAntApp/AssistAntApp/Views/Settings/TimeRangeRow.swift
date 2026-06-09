import SwiftUI

/// One time-range row inside an AnnouncementHoursDayRow. Start and end pickers
/// side-by-side with a remove button.
struct TimeRangeRow: View {
    @Binding var range: TimeRange
    let onDelete: () -> Void

    /// True when start <= end. Invalid ranges (start > end) silently
    /// no-fire in `AnnouncementHours.isActive` because `isWithin` short-
    /// circuits to false; the warning icon below tells the user *why*
    /// chimes aren't playing for this row.
    private var isValid: Bool {
        range.start <= range.end
    }

    var body: some View {
        HStack(spacing: 8) {
            // Indent under the day's checkbox label.
            Spacer().frame(width: 22)
            timeField(for: $range.start)
            Text("—")
                .foregroundStyle(.secondary)
            timeField(for: $range.end)

            if !isValid {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(
                        "End time is before start time — this range "
                        + "will not fire."
                    )
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove range")
        }
    }

    private func timeField(for binding: Binding<TimeOfDay>) -> some View {
        DatePicker(
            "",
            selection: dateBinding(for: binding),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .frame(width: 90)
    }

    /// SwiftUI's DatePicker works in Date, but TimeOfDay is the
    /// persistence model. Bridge by composing a Date at "today" + the
    /// stored hour/minute, and decomposing back on set.
    private func dateBinding(for tod: Binding<TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: tod.wrappedValue.hour,
                    minute: tod.wrappedValue.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute], from: newDate
                )
                tod.wrappedValue = TimeOfDay(
                    hour: components.hour ?? 0,
                    minute: components.minute ?? 0
                )
            }
        )
    }
}
