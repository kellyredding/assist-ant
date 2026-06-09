import SwiftUI

/// "Announce" card for the Calendar tab. A deliberate copy of the Time
/// tab's `AnnounceCard` — same layout and output rows — with the interval
/// picker replaced by a lead-time checklist plus an "Event start" toggle,
/// and "Speak the time" relabeled "Speak the event".
struct CalendarAnnounceCard: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        SettingsCard(title: "Announce") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Enable",
                    isOn: $settingsManager.settings.calendarAnnouncement.enabled
                )
                .toggleStyle(.checkbox)

                Group {
                    leadTimesRow
                    eventStartRow
                    soundRow
                    speechRow
                }
                .disabled(!settingsManager.settings.calendarAnnouncement.enabled)
            }
        }
    }

    // MARK: Lead times

    private var leadTimesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Announce before event")
            HStack(spacing: 16) {
                ForEach(CalendarAnnouncementSettings.leadPresets, id: \.self) { m in
                    Toggle("\(m)m", isOn: leadBinding(m))
                        .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 22)  // align under the label, past the row inset
        }
    }

    private var eventStartRow: some View {
        Toggle(
            "Event start",
            isOn: $settingsManager.settings.calendarAnnouncement.announceStart
        )
        .toggleStyle(.checkbox)
        // Indent to match the lead-time row above, so this checkbox lines
        // up under "1m" — it reads as the 0-minute member of that group.
        .padding(.leading, 22)
    }

    /// Set-membership binding for one preset checkbox.
    private func leadBinding(_ minutes: Int) -> Binding<Bool> {
        Binding(
            get: {
                settingsManager.settings.calendarAnnouncement
                    .leadMinutes.contains(minutes)
            },
            set: { on in
                if on {
                    settingsManager.settings.calendarAnnouncement
                        .leadMinutes.insert(minutes)
                } else {
                    settingsManager.settings.calendarAnnouncement
                        .leadMinutes.remove(minutes)
                }
            }
        )
    }

    // MARK: Outputs (copied from AnnounceCard, retargeted bindings)

    private var soundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Play a sound",
                isOn: $settingsManager.settings.calendarAnnouncement.playSound
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.calendarAnnouncement.playSound {
                HStack {
                    Text("Sound").padding(.leading, 22)
                    Spacer()
                    Picker(
                        "",
                        selection: $settingsManager.settings.calendarAnnouncement.sound
                    ) {
                        ForEach(AnnouncementSound.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    Button {
                        AudioAnnouncementCoordinator.shared.preview(
                            sound: settingsManager.settings.calendarAnnouncement.sound,
                            speech: nil,
                            voiceIdentifier: nil
                        )
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview")
                }
            }
        }
    }

    private var speechRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Speak the event",
                isOn: $settingsManager.settings.calendarAnnouncement.speakEvent
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.calendarAnnouncement.speakEvent {
                HStack {
                    Text("Voice").padding(.leading, 22)
                    Spacer()
                    Picker(
                        "",
                        selection: $settingsManager.settings.calendarAnnouncement.voiceIdentifier
                    ) {
                        Text("System default").tag(String?.none)
                        ForEach(VoiceCatalog.localeVoices()) { entry in
                            Text(entry.displayName).tag(String?.some(entry.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)

                    Button {
                        AudioAnnouncementCoordinator.shared.preview(
                            sound: nil,
                            speech: SpeechAnnouncer.eventPhrase(
                                title: "Standup", minutesBefore: 5
                            ),
                            voiceIdentifier:
                                settingsManager.settings.calendarAnnouncement.voiceIdentifier
                        )
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview")
                }
            }
        }
    }
}
