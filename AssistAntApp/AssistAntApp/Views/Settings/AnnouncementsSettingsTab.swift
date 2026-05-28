import SwiftUI

/// Settings tab for the shared announcement gating — the controls that
/// decide WHEN and WHETHER any audible announcement (time today, desk
/// later) plays. Holds the global "mute while microphone in use" toggle
/// and the weekly schedule, both read by AnnouncementService now and the
/// desk timer in a later phase.
struct AnnouncementsSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Mute") {
                Toggle(
                    "Mute while microphone in use",
                    isOn: $settingsManager.settings.muteWhileMicInUse
                )
                .toggleStyle(.checkbox)
            }

            SettingsCard(title: "Schedule") {
                ScheduleEditor(
                    schedule: $settingsManager.settings.schedule
                )
            }
        }
        .padding(20)
    }
}
