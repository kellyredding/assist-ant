import SwiftUI

/// The Icebox tab's control bar: a label and a refresh glyph that re-fetches
/// the list (the snapshot only updates on activation + this action). Once a
/// selection exists it also shows a count and the shared actions cluster, which
/// then drives the whole selection as a batch.
struct IceboxControlBar: View {
    let onRefresh: () -> Void
    let isWorking: Bool
    @ObservedObject private var model = IceboxModel.shared

    var body: some View {
        HStack(spacing: 12) {
            Text("Items").font(.headline)
            if model.hasSelection {
                Text("\(model.selectedIDs.count) selected")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasSelection {
                // Same cluster as the row hover / reader, fed the selection. A
                // batch omits onChange — the model updates the snapshot and the
                // selection directly. The slots are state-driven (no context).
                ItemActions(items: model.selectedItems)
            }
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
