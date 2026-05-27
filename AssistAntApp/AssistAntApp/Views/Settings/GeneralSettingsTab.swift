import SwiftUI

/// Placeholder content for the General tab. Theme selection (light/dark/
/// system) will land here in a follow-up effort. For now the tab proves the
/// modal + tab-switching plumbing without claiming any real settings.
struct GeneralSettingsTab: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "gear")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("General settings coming soon.")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
