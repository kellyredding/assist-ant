import SwiftUI

/// The Calendar tab's control bar: Today, week chevrons, the live month/year
/// label, and a refresh glyph. All actions are routed to the agenda model.
struct CalendarControlBar: View {
    let monthYear: String
    let onToday: () -> Void
    let onBack: () -> Void
    let onForward: () -> Void
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
