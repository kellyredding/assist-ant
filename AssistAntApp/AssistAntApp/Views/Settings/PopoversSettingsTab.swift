import KeyboardShortcuts
import SwiftUI

/// Popovers settings tab. Groups the shortcuts for AssistAnt's two global,
/// summon-from-any-app popovers into labeled cards:
///
/// - **Capture** — one recorder per `CaptureKind` (label left, recorder flush
///   right) plus the Ask-scoped Wispr auto-start toggle beneath the Ask row.
/// - **Status** — a single recorder that opens the Status popover (the clock /
///   timezone / mute / keyboard-navigable desk controls column).
///
/// The recorders persist through the KeyboardShortcuts library; the Wispr toggle
/// persists through AppSettings.
struct PopoversSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Status") {
                SettingsRow(label: "Open status") {
                    KeyboardShortcuts.Recorder("", name: .statusPopover)
                }
            }

            SettingsCard(title: "Capture") {
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
                "Capture shortcuts open Quick Capture preset to that kind; "
                    + "auto-start applies only when Ask is summoned directly by "
                    + "its shortcut. The status shortcut floats the clock, mute "
                    + "state, and standing-desk controls over any app — the desk "
                    + "controls are keyboard-navigable (arrows, space/return, esc)."
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
