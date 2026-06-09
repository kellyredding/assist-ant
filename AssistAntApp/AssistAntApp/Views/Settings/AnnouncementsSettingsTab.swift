import SwiftUI

/// Settings tab for the shared announcement gating — the controls that
/// decide WHEN and WHETHER any audible announcement (time today, desk
/// later) plays. Holds the global "mute while microphone in use" toggle
/// and the weekly announcement hours, both read by AnnouncementService now
/// and the desk timer in a later phase.
struct AnnouncementsSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    private var enabled: Bool {
        settingsManager.settings.announcementsEnabled
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Enable",
                        isOn: $settingsManager.settings.announcementsEnabled
                    )
                    .toggleStyle(.checkbox)

                    Text("Silence all spoken and chimed time and desk "
                        + "announcements without losing your announcement "
                        + "hours. The clock and desk timer keep working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The announcement hours and mic-mute only shape *when*
            // announcements play, so they are inert (and dimmed) while
            // announcements are globally off. Their values are preserved.
            SettingsCard(title: "Mute") {
                Toggle(
                    "Mute while microphone in use",
                    isOn: $settingsManager.settings.muteWhileMicInUse
                )
                .toggleStyle(.checkbox)
            }
            .disabled(!enabled)

            SettingsCard(title: "Announcement Hours") {
                AnnouncementHoursEditor(
                    announcementHours: $settingsManager.settings.announcementHours
                )
            }
            .disabled(!enabled)
        }
        .padding(20)
    }
}
