import SwiftUI

/// Time settings tab. Currently hosts the Format card with the 12-hour /
/// 24-hour picker. Future time-related settings (announcements, chime,
/// quiet hours) wrap themselves in their own SettingsCard and slot in
/// below.
struct TimeSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Format") {
                SettingsRow(label: "Time format") {
                    Picker("", selection: $settingsManager.settings.timeFormat) {
                        ForEach(TimeFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Spacer()
        }
        .padding(20)
    }
}
