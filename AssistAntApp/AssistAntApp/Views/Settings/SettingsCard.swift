import SwiftUI

/// Grouped section in a settings tab. Title above, content in a rounded
/// control-background box below. One card per logical grouping of related
/// settings (Appearance, Notifications, etc.).
///
/// Adapted from Galaxy's inline SettingsCard
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 12)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}
