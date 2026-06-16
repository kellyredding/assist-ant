import KeyboardShortcuts
import SwiftUI

/// Capture settings tab. One recorder row per `CaptureKind` (label left,
/// recorder flush right) plus the Ask-scoped Wispr auto-start toggle directly
/// beneath the Ask row. The recorders persist through the KeyboardShortcuts
/// library; the toggle persists through AppSettings.
struct CaptureSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Shortcuts") {
                VStack(alignment: .leading, spacing: 12) {
                    // Ask + its auto-start sub-option, grouped (tighter spacing)
                    // so the checkbox reads as belonging to the Ask shortcut.
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsRow(label: "Ask") {
                            KeyboardShortcuts.Recorder("", name: .captureAsk)
                        }

                        // Standard left checkbox + trailing label, tabbed in
                        // under Ask. Scoped to Ask: only a direct Ask summon
                        // auto-arms Wispr.
                        Toggle(
                            "Auto-start Wispr hands-free",
                            isOn: $settingsManager.settings.captureAutoArmWisprOnAsk
                        )
                        .toggleStyle(.checkbox)
                        .padding(.leading, 22)
                    }

                    SettingsRow(label: "To-do") {
                        KeyboardShortcuts.Recorder("", name: .captureTodo)
                    }

                    SettingsRow(label: "Reminder") {
                        KeyboardShortcuts.Recorder("", name: .captureReminder)
                    }

                    SettingsRow(label: "Explore") {
                        KeyboardShortcuts.Recorder("", name: .captureExplore)
                    }

                    SettingsRow(label: "Task") {
                        KeyboardShortcuts.Recorder("", name: .captureTask)
                    }
                }
            }

            Text(
                "Each shortcut opens Quick Capture preset to that kind. "
                    + "Auto-start applies only when Ask is summoned directly by "
                    + "its shortcut — not when switching to Ask inside an open popover."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
    }
}
