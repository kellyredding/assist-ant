import SwiftUI

/// The Icebox tab's control bar: a label and a refresh glyph that re-fetches
/// the list (the snapshot only updates on activation + this action).
struct IceboxControlBar: View {
    let onRefresh: () -> Void
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("Icebox").font(.headline)
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                PointerIconButton(
                    systemName: "arrow.clockwise",
                    help: "Reload the icebox", action: onRefresh
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}
