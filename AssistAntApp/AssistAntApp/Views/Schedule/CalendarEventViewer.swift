import SwiftUI

/// Full-takeover reader for a single calendar event, shown inside the Schedule
/// tab in place of the agenda. Three stacked zones: a header (centered title +
/// close button), a sticky date/time line, then the scrollable event body.
/// Mirrors the reader pattern used by Galaxy's snapshot viewer; the Escape
/// monitor and the `openEvent` toggle live in `SchedulePaneView`, which owns
/// dismissal — this view just reports a close intent via `onClose`.
struct CalendarEventViewer: View {
    let event: Item
    let onClose: () -> Void

    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            timeBar
            // AppKit-backed so links get the pointing-hand cursor + hover
            // underline and the body stays selectable; it scrolls internally.
            EventBodyTextView(markdown: event.body ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: this sits over the still-mounted agenda in a ZStack, so it
        // must fully cover it (the body view draws no background of its own).
        .background(Color(.textBackgroundColor))
    }

    // MARK: - Header

    // Title centered over the full width with the close button overlaid on the
    // right (a ZStack, not an HStack), so the title stays optically centered
    // regardless of the button. No left back-button — this is a modal-style
    // takeover, dismissed by ✕ or Escape.
    private var header: some View {
        ZStack {
            Text(event.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 36)   // clear of the ✕ on the right

            HStack {
                Spacer()
                // Same icon-button component as the control bar's glyphs, so
                // the close affordance carries the identical hover highlight
                // and pointing-hand cursor.
                PointerIconButton(
                    systemName: "xmark",
                    help: "Close (Esc)",
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    // MARK: - Time bar

    // Sticky between the header and the scrolling body — not inside the
    // ScrollView — so the when-and-where stays visible while the body scrolls.
    private var timeBar: some View {
        HStack(spacing: 8) {
            Text(timeLineText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            CalendarActions(item: event)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Derived content

    private var calendarData: CalendarData? {
        if case .calendar(let d) = event.typeData { return d }
        return nil
    }

    /// The sticky line: `Mon, Jun 9  ·  10:00 AM – 11:00 AM` (times in local
    /// time, like the agenda rows), `· All Day` for all-day events, and the
    /// event's source timezone appended only when it differs from local.
    private var timeLineText: String {
        guard let d = calendarData else { return "" }

        let dayString: String
        if let start = d.startAt {
            dayString = Self.dayFormatter.string(from: start)
        } else if let sched = event.scheduledOn {
            dayString = Self.dayFormatter.string(from: sched.noon)
        } else {
            dayString = ""
        }

        if d.allDay {
            return "\(dayString)  ·  All Day"
        }

        guard let start = d.startAt else { return dayString }

        var line = "\(dayString)  ·  \(timeString(start))"
        if let end = d.endAt {
            line += " – \(timeString(end))"
        }
        if let tz = d.timeZoneID, tz != TimeZone.current.identifier {
            line += "  ·  \(tz)"
        }
        return line
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = settings.settings.timeFormat.dateFormat
        return f.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"   // e.g. "Mon, Jun 9"
        return f
    }()
}
