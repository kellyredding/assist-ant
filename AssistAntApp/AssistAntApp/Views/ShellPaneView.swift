import Combine
import SwiftUI
import Galactic

/// Container for the shell pane: the drag bar on top, the terminal below.
/// Built by `TerminalTabSplitView` while the split is open.
struct ShellPaneView: View {
    @ObservedObject var pane: ShellTerminalPane
    let isVisibleSurface: Bool
    let onBarDragBegan: () -> Void
    let onBarDrag: (CGFloat) -> Void
    let onBarDragEnded: () -> Void
    let onBarDoubleClick: () -> Void

    /// What can stop the agent beside this shell being written to. The shell
    /// sends into that agent, so the shell's own state is not the question.
    private var sendBlockerChanges: SendBlockerChanges {
        AgentSessionController.shared.$state
            .map { _ in () }
            .eraseToAnyPublisher()
    }

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
                // No timeline here, so there is nowhere to record into.
                timelineRecorder: nil,
                settings: SettingsManager.shared,
                findActivations: MenuActions.findActivations,
                scrollbackActivations: MenuActions.scrollbackActivations,
                // No turns happen in a shell, so there is nothing here to
                // interrupt.
                turnInterrupt: nil,
                paneRegistry: TerminalPanes.shared,
                // A shell's own exit does not close its scrollback today, and
                // the agent stopping is not this surface's ending either.
                surfaceEndings: .never,
                sendBlockerChanges: sendBlockerChanges,
                isActiveSession: true,
                isVisibleSurface: isVisibleSurface,
                // This app never hides a pane, so the tab ceasing to show is
                // the whole question.
                shouldResignFocus: !isVisibleSurface)
                .equatable()
        }
    }
}
