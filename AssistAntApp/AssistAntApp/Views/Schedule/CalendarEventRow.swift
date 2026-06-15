import SwiftUI

/// One event in the agenda: an aligned time column and the title. Past events
/// (already ended) render dimmed, matching the today sidebar.
struct CalendarEventRow: View {
    let item: Item
    let isPast: Bool
    /// Invoked when the row is tapped, to open the event in the reader.
    let onTap: () -> Void
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isHovering = false
    /// Anchors the hover tooltip to this row's live screen frame.
    @State private var tipAnchor = RowFrameAnchor()

    var body: some View {
        rowContent
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .background(FrameAnchorView(anchor: tipAnchor))
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            // Overlay (not a ZStack child) so the cluster never changes row height.
            .overlay(alignment: .trailing) {
                if isHovering {
                    CalendarActions(item: item)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                }
            }
            // Hover via .onHover (not the row pointerButton) so it keeps firing
            // while the pointer is over the overlaid cluster, whose own
            // pointerButtons stay hit-testable on top (the ActionableRow pattern).
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    // Schedule rows hang the tooltip to the left, over the sidebar.
                    ItemTooltipController.shared.requestShow(
                        item, anchor: tipAnchor, side: .left)
                } else {
                    ItemTooltipController.shared.requestHide(tipAnchor)
                }
            }
            .onDisappear { ItemTooltipController.shared.hideNow() }
    }

    /// The time + title row; the tap is an inner pointerButton so the hover
    /// cluster's own buttons aren't shadowed by a row-wide button.
    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            timeColumns
            Text(item.title)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .opacity(isPast ? 0.45 : 1.0)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .pointerButton(onHoverChange: { _ in }, action: onTap)
    }

    /// Start and end in separate right-aligned columns with the dash between,
    /// so minutes and AM/PM line up vertically across rows and a range of two
    /// two-digit hours never wraps. The end columns are blank when the event
    /// has no end but keep their width, so titles stay aligned regardless.
    private var timeColumns: some View {
        HStack(spacing: 0) {
            Text(timeString(startAt))
                .frame(width: 68, alignment: .trailing)
            Text(endAt != nil ? "–" : "")
                .frame(width: 24, alignment: .center)   // own column, centered
            Text(endAt != nil ? timeString(endAt) : "")
                .frame(width: 68, alignment: .leading)
        }
        .font(.callout).monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var startAt: Date? {
        if case .calendar(let d) = item.typeData { return d.startAt }
        return nil
    }

    private var endAt: Date? {
        if case .calendar(let d) = item.typeData { return d.endAt }
        return nil
    }

    /// `date` in local time, honoring the 12/24-hour preference.
    private func timeString(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = settings.settings.timeFormat.dateFormat
        return f.string(from: date)
    }
}
