import SwiftUI

/// General settings tab. Currently hosts the Appearance card with a Theme
/// picker. Future general settings (quiet hours, etc.) wrap themselves in
/// their own SettingsCard and slot in here.
struct GeneralSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Appearance") {
                SettingsRow(label: "Theme") {
                    Picker("", selection: $settingsManager.settings.themePreference) {
                        ForEach(ThemePreference.allCases, id: \.self) { preference in
                            Label(
                                preference.displayName,
                                systemImage: preference.iconName
                            )
                            .tag(preference)
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
