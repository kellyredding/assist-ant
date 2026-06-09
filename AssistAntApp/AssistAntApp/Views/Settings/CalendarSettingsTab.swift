import SwiftUI

/// Calendar settings tab. Hosts the Announce card for upcoming-event
/// announcements. Structured to match the Time tab so the two read as
/// siblings; future calendar-related cards slot in here in their own
/// SettingsCard.
struct CalendarSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            CalendarAnnounceCard(settingsManager: settingsManager)
        }
        .padding(20)
    }
}
