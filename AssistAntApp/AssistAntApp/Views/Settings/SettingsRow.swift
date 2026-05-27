import SwiftUI

/// One row inside a SettingsCard: label on the left, control on the right.
/// The content closure produces the control (Picker, Toggle, TextField,
/// Stepper, etc.). Stretching Spacer between them keeps the control flush
/// to the right edge of the card.
///
/// Adapted from Galaxy's inline SettingsRow
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}
