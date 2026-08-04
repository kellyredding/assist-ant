import SwiftUI

/// The Trash tab's control bar: a label and a refresh glyph that re-fetches the
/// list (the snapshot only updates on activation + this action). Once a
/// selection exists it also shows a count and the scaled-back TrashActions
/// cluster, which then drives the whole selection as a batch.
struct TrashControlBar: View {
    let groups: [ActionableGroup]
    let collapsedLists: Set<String>
    @ObservedObject var selection: ActionableSelection
    let actions: ActionableActions
    let onRefresh: () -> Void
    let isWorking: Bool

    var body: some View {
        // Resolved once, and the count reads the same array the cluster acts on.
        // `hasSelection` counts ids a collapsed group may be hiding, so gating on
        // it showed a count the buttons could not honour.
        let selected = selection.selectedItems(in: groups, collapsed: collapsedLists)
        HStack(spacing: 12) {
            Text("Trash").font(.headline)
            if !selected.isEmpty {
                Text("\(selected.count) selected")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !selected.isEmpty {
                // Same trash cluster as the row hover / reader, fed the
                // selection. The batch omits onChange — the actions update the
                // snapshot + the selection directly.
                TrashActions(
                    items: selected,
                    actions: actions,
                    showsMnemonics: true
                )
            }
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                PointerIconButton(
                    systemName: "arrow.clockwise",
                    help: "Reload trash", action: onRefresh
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}
