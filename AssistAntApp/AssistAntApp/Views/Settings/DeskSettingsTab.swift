import SwiftUI

/// Desk tab: enable the sit/stand timer, set the two interval durations,
/// and configure the desk's own audio (independent of time
/// announcements) — Play a sound (with its own sound choice) and Speak
/// the alert (with its own voice).
struct DeskSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Timer") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable", isOn: Binding(
                        get: { settingsManager.settings.desk.enabled },
                        set: { DeskService.shared.setEnabled($0) }
                    ))
                    .toggleStyle(.checkbox)

                    Group {
                        intervalRow(
                            label: "Sit for",
                            minutes: $settingsManager.settings.desk.sitMinutes
                        )
                        intervalRow(
                            label: "Stand for",
                            minutes: $settingsManager.settings.desk.standMinutes
                        )
                        soundRow
                        speechRow
                    }
                    .disabled(!settingsManager.settings.desk.enabled)
                }
            }
        }
        .padding(20)
    }

    /// A type-or-step minute field. The text field and the stepper share
    /// one clamped binding: you can type a value directly or nudge it with
    /// the arrows in 1-minute steps. The only constraint is a floor of 1
    /// minute (clamped on both typed entry and the stepper's lower bound);
    /// there is intentionally no upper limit.
    private func intervalRow(
        label: String,
        minutes: Binding<Int>
    ) -> some View {
        let clamped = Binding<Int>(
            get: { minutes.wrappedValue },
            set: { minutes.wrappedValue = max(1, $0) }
        )
        return SettingsRow(label: label) {
            HStack(spacing: 6) {
                TextField("", value: clamped, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                Text("min")
                    .foregroundStyle(.secondary)
                Stepper("", value: clamped, in: 1...Int.max, step: 1)
                    .labelsHidden()
            }
        }
    }

    private var soundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Play a sound",
                isOn: $settingsManager.settings.desk.playSound
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.desk.playSound {
                HStack {
                    Text("Sound")
                        // Align label with toggle text — the checkbox glyph
                        // takes about 22pt.
                        .padding(.leading, 22)
                    Spacer()
                    Picker(
                        "",
                        selection: $settingsManager.settings.desk.sound
                    ) {
                        ForEach(AnnouncementSound.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)

                    Button {
                        AudioAnnouncementCoordinator.shared.preview(
                            sound: settingsManager.settings.desk.sound,
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
                "Speak the alert",
                isOn: $settingsManager.settings.desk.speakAlert
            )
            .toggleStyle(.checkbox)

            if settingsManager.settings.desk.speakAlert {
                HStack {
                    Text("Voice")
                        .padding(.leading, 22)  // align with Toggle text
                    Spacer()
                    Picker(
                        "",
                        selection: $settingsManager.settings.desk.voiceIdentifier
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
                            speech: "Time to stand",
                            voiceIdentifier:
                                settingsManager.settings.desk.voiceIdentifier
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
