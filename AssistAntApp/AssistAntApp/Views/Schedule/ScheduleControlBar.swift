import SwiftUI

/// The Schedule tab's control bar: Today, week chevrons, the live month/year
/// label, a button that opens Google Calendar in the browser, and a refresh
/// glyph. Navigation and refresh route to the agenda model; the browser
/// button opens an external URL.
struct ScheduleControlBar: View {
    let monthYear: String
    let onToday: () -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onOpenGoogleCalendar: () -> Void
    let onRefresh: () -> Void
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 12) {
            CapsuleActionButton(title: "Today", action: onToday)
            PointerIconButton(
                systemName: "chevron.left", help: "Back one week", action: onBack
            )
            PointerIconButton(
                systemName: "chevron.right", help: "Forward one week",
                action: onForward
            )
            Text(monthYear)
                .font(.headline)
            Spacer()
            // Same glyph component as refresh (hover highlight + hand cursor);
            // independent of sync state, so it stays put while a sync swaps the
            // refresh glyph for a spinner.
            PointerIconButton(
                systemName: "arrow.up.right.square",
                help: "Open Google Calendar in browser",
                action: onOpenGoogleCalendar
            )
            // Swap the refresh glyph for a spinner while a sync is in flight,
            // matching the sidebar affordance.
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                PointerIconButton(
                    systemName: "arrow.clockwise", help: "Reload events in view",
                    action: onRefresh
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}
