import SwiftUI

/// Desk tab: enable the sit/stand timer and set the two interval
/// durations. No audio settings yet — the output toggles (a sound, a
/// spoken alert) plus an own sound and an own voice arrive once the
/// shared audio pipeline lands.
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
}
