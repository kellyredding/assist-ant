import SwiftUI

/// One calendar event in the today sidebar: start time and title. Past events
/// (already ended) render dimmed but remain for context.
struct CalendarItemRow: View {
    let row: TodayCalendarRow
    /// Invoked when the row is tapped, to open the event in the Calendar tab.
    let onTap: () -> Void
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isHovering = false
    /// Anchors the hover tooltip to this row's live screen frame.
    @State private var tipAnchor = RowFrameAnchor()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeText)
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(row.item.title)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .opacity(row.isPast ? 0.45 : 1.0)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        )
        .background(FrameAnchorView(anchor: tipAnchor))
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        // Outermost: the pointerButton overlay owns the click and the
        // pointing-hand cursor, so it must stay topmost (see PointerButton).
        .pointerButton(
            onHoverChange: { hovering in
                isHovering = hovering
                if hovering {
                    // Today rows hang the tooltip to the right, into the pane.
                    ItemTooltipController.shared.requestShow(
                        row.item, anchor: tipAnchor, side: .right)
                } else {
                    ItemTooltipController.shared.requestHide(tipAnchor)
                }
            },
            action: onTap
        )
        .onDisappear { ItemTooltipController.shared.hideNow() }
    }

    /// Start time in local time, honoring the 12/24-hour preference (same
    /// format source the clock uses).
    private var timeText: String {
        guard let start = TodayCalendar.startAt(row.item) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = settings.settings.timeFormat.dateFormat
        return formatter.string(from: start)
    }
}
