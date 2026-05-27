import SwiftUI

/// One button in the horizontal tab strip at the top of SettingsView. Icon
/// over title; selected state gets a subtle filled background.
///
/// Adapted verbatim from
/// ~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Views/SettingsView.swift
struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
    }
}
