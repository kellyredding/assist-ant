import SwiftUI
import Galactic

/// General settings tab. Hosts the Appearance card with a Theme picker, and
/// the Text entry card. Future general settings (quiet hours, etc.) wrap
/// themselves in their own SettingsCard and slot in here.
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

            // Not the Terminal tab: these keystrokes govern the WebView note
            // forms and the local composers as well as the agent session pane.
            SettingsCard(title: "Text entry") {
                VStack(alignment: .leading, spacing: 12) {
                    KeystrokeListEditor(
                        label: "Submit",
                        keystrokes: $settingsManager.settings.textEntry.submit,
                        siblingLabel: "Newline",
                        sibling: $settingsManager.settings.textEntry.newline
                    )
                    KeystrokeListEditor(
                        label: "Newline",
                        keystrokes: $settingsManager.settings.textEntry.newline,
                        siblingLabel: "Submit",
                        sibling: $settingsManager.settings.textEntry.submit
                    )
                    Text(
                        "Applies to note forms and local composers. A reader "
                            + "that is already open keeps its previous "
                            + "keystrokes until it is reopened."
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                    ClaudeKeybindingsSyncRow(
                        settingsManager: settingsManager)
                }
            }

            Spacer()
        }
        .padding(20)
    }
}
