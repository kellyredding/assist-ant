import SwiftUI

/// "Announce" settings card. Sits in the Time tab below the Format
/// card. Master Enable gates the whole card; when off, the inner
/// controls grey out.
///
/// Two independent output toggles — "Play a sound" and "Speak the
/// time" — control what fires. Either, both, or neither can be on.
/// When both are on, the chime sequence plays first and speech
/// follows at the inter-chime cadence (see
/// `AnnouncementService.evaluate`).
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
                    speechRow
                    micMuteRow
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

    private var speechRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Speak the time",
                isOn: $settingsManager.settings.announcement.speakTime
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.announcement.speakTime {
                voicePickerRow
            }
        }
    }

    private var micMuteRow: some View {
        Toggle(
            "Mute while microphone in use",
            isOn: $settingsManager.settings.announcement.muteWhileMicInUse
        )
        .toggleStyle(.checkbox)
    }

    private var voicePickerRow: some View {
        HStack {
            Text("Voice")
                .padding(.leading, 22)  // align with Toggle text
            Spacer()
            Picker(
                "",
                selection: $settingsManager.settings.announcement.voiceIdentifier
            ) {
                Text("System default").tag(String?.none)
                ForEach(voiceEntries) { entry in
                    Text(entry.displayName).tag(String?.some(entry.id))
                }
            }
            .labelsHidden()
            .frame(width: 220)

            Button {
                previewSpeech()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Preview")
        }
    }

    /// Voice list shown in the picker. Filtered to the current locale
    /// — most users want the voices that match the system language,
    /// not the full cross-locale catalog. Recomputes on each render;
    /// the underlying `AVSpeechSynthesisVoice.speechVoices()` call is
    /// cached by AVFoundation, so this is cheap.
    private var voiceEntries: [VoiceEntry] {
        VoiceCatalog.localeVoices()
    }

    /// Speak a fixed demo time (3:00 PM in 12-hour mode, 15:00 in
    /// 24-hour) through the currently selected voice. Demo time is
    /// fixed rather than `now` so the preview is consistent and so
    /// the preview doesn't reveal the current minute to anyone who
    /// happens to be listening.
    private func previewSpeech() {
        let calendar = Calendar.current
        let demo = calendar.date(
            bySettingHour: 15, minute: 0, second: 0, of: Date()
        ) ?? Date()
        SpeechAnnouncer.shared.speak(
            time: demo,
            format: settingsManager.settings.timeFormat,
            voiceIdentifier: settingsManager.settings.announcement.voiceIdentifier
        )
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
