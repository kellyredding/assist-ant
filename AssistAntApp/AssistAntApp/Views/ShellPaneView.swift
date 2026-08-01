import SwiftUI
import Galactic

/// Container for the shell pane: the drag bar on top, the terminal below.
/// Built by `TerminalTabSplitView` while the split is open.
struct ShellPaneView: View {
    @ObservedObject var pane: ShellTerminalPane
    let isActive: Bool
    let onBarDragBegan: () -> Void
    let onBarDrag: (CGFloat) -> Void
    let onBarDragEnded: () -> Void
    let onBarDoubleClick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ShellPaneBar(
                onDragBegan: onBarDragBegan,
                onDrag: onBarDrag,
                onDragEnded: onBarDragEnded,
                onResetSplit: onBarDoubleClick
            )
            .frame(height: 28)

            // `.equatable()` opts into FocusableTerminalView's Equatable
            // conformance so SwiftUI skips updateNSView when neither the pane
            // nor its active state changed.
            FocusableTerminalView(
                pane: pane,
                isActiveSession: true,
                isVisibleSurface: isActive,
                paneRegistry: TerminalPanes.shared)
                .equatable()
        }
    }
}
