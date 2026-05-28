import SwiftUI

/// Time settings tab. Hosts the Format card with the 12-hour / 24-hour
/// picker and the Announce card with the scheduled-chime settings.
/// Future time-related cards (e.g. quiet hours that aren't part of the
/// announce schedule) wrap themselves in their own SettingsCard and slot
/// in here.
struct TimeSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Format") {
                SettingsRow(label: "Time format") {
                    Picker(
                        "",
                        selection: $settingsManager.settings.timeFormat
                    ) {
                        ForEach(TimeFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            AnnounceCard(settingsManager: settingsManager)
        }
        .padding(20)
    }
}
