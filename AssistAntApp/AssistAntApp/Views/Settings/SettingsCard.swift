import SwiftUI

/// Grouped section in a settings tab. Title above, content in a rounded
/// control-background box below. One card per logical grouping of related
/// settings (Appearance, Notifications, etc.).
///
/// The box stretches to the full available width (leading-aligned
/// content) so cards read as a consistent left-justified column
/// regardless of how wide their content is. Cards whose content already
/// fills the width via a `SettingsRow` Spacer are unaffected; cards with
/// a single narrow control (e.g. a lone Toggle) would otherwise shrink to
/// hug the control and get centered by the parent stack.
///
/// Adapted from Galaxy's inline SettingsCard
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift).
struct SettingsCard<Content: View>: View {
    /// Optional section title above the box. Omit it for a bare card (e.g.
    /// a single lead toggle that needs no heading).
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
                    .padding(.bottom, 6)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}
