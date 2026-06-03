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
                    // Hug + pin trailing so the right edge lands on the
                    // card margin, flush with the Announce card's preview
                    // buttons below (matching the Desk tab's alignment).
                    .fixedSize()
                }
            }

            AnnounceCard(settingsManager: settingsManager)
        }
        .padding(20)
    }
}
