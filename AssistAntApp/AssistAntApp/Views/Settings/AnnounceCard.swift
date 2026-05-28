import SwiftUI

/// "Announce" settings card. Sits in the Time tab below the Format card.
/// Master Enable toggle gates the whole card; when off, the inner
/// controls grey out. Phase 1 has "Play a sound" with sound picker +
/// preview, an interval picker, and the schedule editor.
struct AnnounceCard: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        SettingsCard(title: "Announce") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Enable",
                    isOn: $settingsManager.settings.announcement.enabled
                )
                .toggleStyle(.checkbox)

                Group {
                    soundRow
                    intervalRow
                    scheduleSection
                }
                .disabled(!settingsManager.settings.announcement.enabled)
            }
        }
    }

    private var soundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Play a sound",
                isOn: $settingsManager.settings.announcement.playSound
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.announcement.playSound {
                HStack {
                    Text("Sound")
                        // Align label with toggle text — the checkbox glyph
                        // takes about 22pt.
                        .padding(.leading, 22)
                    Spacer()
                    Picker(
                        "",
                        selection: $settingsManager.settings.announcement.sound
                    ) {
                        ForEach(AnnouncementSound.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    Button {
                        settingsManager.settings.announcement.sound.play()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview")
                }
            }
        }
    }

    private var intervalRow: some View {
        SettingsRow(label: "Interval") {
            Picker(
                "",
                selection: $settingsManager.settings.announcement.interval
            ) {
                ForEach(AnnouncementInterval.allCases, id: \.self) { iv in
                    Text(iv.displayName).tag(iv)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schedule")
            ScheduleEditor(
                schedule: $settingsManager.settings.announcement.schedule
            )
        }
    }
}
