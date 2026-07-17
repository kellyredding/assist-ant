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
                    SettingsRow(label: "Ask") {
                        KeyboardShortcuts.Recorder("", name: .captureAsk)
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

                    // Applies to every kind: a direct summon of any capture tab
                    // auto-starts Wispr hands-free dictation. Full-width (no
                    // indent) so it reads as a card-level option rather than a
                    // child of the Task row above it.
                    Toggle(
                        "Auto-start Wispr hands-free",
                        isOn: $settingsManager.settings.captureAutoArmWispr
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Text(
                "Capture shortcuts open Quick Capture preset to that kind; "
                    + "auto-start applies to a direct summon of any kind, not to "
                    + "switching kinds inside an open popover. The status shortcut "
                    + "floats the clock, mute state, and standing-desk controls "
                    + "over any app — the desk controls are keyboard-navigable "
                    + "(arrows, space/return, esc)."
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
