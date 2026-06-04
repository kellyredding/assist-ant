import SwiftUI

/// The agent pane — the right side of the main window. An embedded Claude
/// Code session will live here; until then this renders a calm, themed empty
/// area so the split layout reads as intentional rather than broken. Fills
/// all the space the resizable sidebar leaves.
struct AgentPaneView: View {
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)

                Text("Agent")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Coming soon")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
