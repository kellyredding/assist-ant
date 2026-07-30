import AppKit
import Combine
import SwiftUI
import Galactic

/// Split container for the Terminal tab. The session pane is always on top;
/// a shell pane joins it below once opened.
///
/// Split state — the ratio, whether a shell is open, and the shell pane
/// itself — lives here and is deliberately not persisted, so a relaunch
/// always comes back to a plain single terminal.
struct TerminalTabSplitView: View {
    @ObservedObject private var navigator = MainTabNavigator.shared
    @StateObject private var state = SplitState()

    /// Tightest allowed top-pane ratio. Below this the session pane is too
    /// small to be useful, so a drag locks here rather than continuing.
    private static let minRatio: CGFloat = 0.30

    /// Loosest allowed top-pane ratio. Above this the shell is too small to
    /// type into.
    private static let maxRatio: CGFloat = 0.70

    private var isActive: Bool { navigator.selectedTab == .terminal }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let topHeight = clampedTopHeight(totalHeight: totalHeight)

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    SessionPaneView()
                        .frame(
                            height: state.shellPane == nil
                                ? totalHeight : topHeight
                        )

                    if let shellPane = state.shellPane {
                        ShellPaneView(
                            pane: shellPane,
                            isActive: isActive,
                            onBarDragBegan: {
                                state.beginDragPreview()
                            },
                            onBarDrag: { delta in
                                state.updateDragPreview(
                                    cursorDeltaY: delta,
                                    totalHeight: totalHeight,
                                    minRatio: Self.minRatio,
                                    maxRatio: Self.maxRatio
                                )
                            },
                            onBarDragEnded: {
                                state.commitDragPreview()
                            },
                            onBarDoubleClick: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.ratio = Self.configuredTopRatio()
                                }
                            }
                        )
                        .frame(height: totalHeight - topHeight)
                    }
                }

                // Ghost line, shown only mid-drag. It tracks the cursor live
                // so neither terminal buffer reflows until the drag commits.
                if let preview = state.dragPreviewRatio,
                   state.shellPane != nil {
                    DragPreviewLineView(
                        shellPercentage: Int(
                            ((1.0 - preview) * 100).rounded()
                        )
                    )
                    .frame(height: 1)
                    .offset(y: totalHeight * preview)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .onReceive(TerminalTabCommands.shared.openShell) { _ in
            if state.shellPane != nil {
                // Already open, so this means "focus it" — through the
                // registry rather than the pane, so a scrollback open on the
                // shell keeps focus instead of the live terminal behind it.
                // Focusing the pane directly leaves the overlay visible but
                // keyboard-dead, with Esc going to the shell as input.
                TerminalPanes.shared.restoreShellPaneFocus()
            } else {
                state.openShell()
            }
        }
        .onReceive(TerminalTabCommands.shared.focusSession) { _ in
            // Through the registry, not the backend: with a scrollback open
            // on the session pane, focusing the backend would land on the
            // live terminal hidden behind the overlay. Galaxy's own ⌘T goes
            // straight to the backend and has exactly that bug.
            TerminalPanes.shared.restoreSessionPaneFocus()
        }
        .onReceive(TerminalTabCommands.shared.closeFocusedShell) { _ in
            guard let pane = state.shellPane else { return }
            // Gate the close on a confirmation when the shell's scrollback
            // holds notes. The helper closes straight through when there is
            // nothing to lose, so the common case is unchanged.
            TerminalPanes.shared.confirmAndCloseShellPane {
                pane.requestClose()
            }
        }
    }

    private func clampedTopHeight(totalHeight: CGFloat) -> CGFloat {
        let clampedRatio = min(
            max(state.ratio, Self.minRatio), Self.maxRatio
        )
        return totalHeight * clampedRatio
    }

    /// Top-pane fraction derived from the configured default shell height.
    /// Clamped to the same window the drag enforces, so the setting can never
    /// disagree with live drag bounds. Used on shell open and on reset.
    static func configuredTopRatio() -> CGFloat {
        let shellRatio = SettingsManager.shared.settings
            .shellDefaultHeightRatio
        let range = AppSettings.shellDefaultHeightRatioRange
        let clampedShell = min(
            max(shellRatio, range.lowerBound), range.upperBound
        )
        return CGFloat(1.0 - clampedShell)
    }
}

/// Mutable split state — ratio, the shell pane, and drag-preview bookkeeping.
/// Held as a `@StateObject` so it survives re-renders but is rebuilt cleanly
/// if the view's identity changes.
final class SplitState: ObservableObject {
    /// Committed split ratio, driving the actual layout. Updated on drag
    /// commit rather than on every cursor tick.
    @Published var ratio: CGFloat = 0.5

    /// Live drag-preview ratio, non-nil only while a drag is in progress.
    /// The ghost line reads this; the panes stay at `ratio` until commit.
    @Published var dragPreviewRatio: CGFloat?

    /// Snapshot of `ratio` at drag start, so repeated updates compute from a
    /// fixed base instead of compounding.
    private var dragStartRatio: CGFloat?

    @Published var shellPane: ShellTerminalPane?

    func openShell() {
        let pane = ShellTerminalPane(
            controller: AgentSessionController.shared
        )

        // Close the pane when the shell exits, whether by `exit` / Ctrl-D or
        // by a signal.
        pane.onProcessExit = { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeShell()
            }
        }

        pane.start()
        ratio = TerminalTabSplitView.configuredTopRatio()
        shellPane = pane

        // Focus the shell on open — the user just asked for it. Deliberately
        // the pane and not its focus restorer, unlike every other focus route
        // here: this shell was created a moment ago, so it can have no
        // scrollback to redirect to, and its host has not registered a
        // restorer yet. The delay gives that host time to reach the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pane.focus()
        }
    }

    func closeShell() {
        shellPane = nil
        // Hand focus back to the session pane through its restorer, so an
        // open scrollback overlay there receives focus rather than the live
        // terminal beneath it. Deliberately the session-specific restorer:
        // the focus memory still reads `.shell` from the user's last
        // keystroke in the pane that just went away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            TerminalPanes.shared.restoreSessionPaneFocus()
        }
    }

    /// Capture the current ratio as the drag baseline, on mouseDown.
    /// `dragPreviewRatio` stays nil until the first movement so a click
    /// without a drag never flashes the ghost line.
    func beginDragPreview() {
        dragStartRatio = ratio
    }

    /// Update the preview from the cursor's Y delta since drag start.
    /// Dragging the bar up shrinks the session pane and grows the shell.
    ///
    /// Always computed from `dragStartRatio` rather than the current preview,
    /// so each tick's delta doesn't stack on the previous frame's. Clamped to
    /// the caller's window, so moving past a threshold locks at the boundary.
    func updateDragPreview(
        cursorDeltaY: CGFloat,
        totalHeight: CGFloat,
        minRatio: CGFloat,
        maxRatio: CGFloat
    ) {
        guard totalHeight > 0, let startRatio = dragStartRatio else {
            return
        }
        let newTop = (startRatio * totalHeight) - cursorDeltaY
        let rawRatio = newTop / totalHeight
        dragPreviewRatio = min(max(rawRatio, minRatio), maxRatio)
    }

    /// Commit the preview, applying the ratio in one step so both terminals
    /// reflow once instead of on every drag tick. A click without a drag
    /// leaves the committed ratio untouched.
    func commitDragPreview() {
        if let preview = dragPreviewRatio {
            ratio = preview
        }
        dragStartRatio = nil
        dragPreviewRatio = nil
    }
}

/// Ghost line shown while the divider is being dragged: one thin line at the
/// proposed divider, with a small label near the right edge. Both use
/// `Color.primary`, which adapts to light and dark.
struct DragPreviewLineView: View {
    let shellPercentage: Int

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.85))
            .overlay(
                Text("Shell \(shellPercentage)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.primary.opacity(0.85))
                    .fixedSize()
                    .padding(.trailing, 10)
                    .offset(y: -14),
                alignment: .trailing
            )
    }
}

/// Pub/sub hub for Terminal-tab menu commands, and the home of the ⌘W
/// interceptor. Galaxy keys each command by session id so only the active
/// session's split responds; with one embedded session the signal carries no
/// payload.
final class TerminalTabCommands {
    static let shared = TerminalTabCommands()

    let openShell = PassthroughSubject<Void, Never>()
    let focusSession = PassthroughSubject<Void, Never>()
    let closeFocusedShell = PassthroughSubject<Void, Never>()

    /// Held for the life of the app so the monitor is never torn down.
    private var cmdWMonitor: Any?

    private init() {
        installCmdWMonitor()
    }

    /// Intercept ⌘W app-wide, consuming it only when the first responder sits
    /// inside a host showing a shell pane — in which case it closes that
    /// shell. Every other ⌘W passes through to Close Window, unchanged.
    private func installCmdWMonitor() {
        cmdWMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self = self else { return event }
            let modsOfInterest: NSEvent.ModifierFlags = [
                .command, .option, .control, .shift,
            ]
            let mods = event.modifierFlags.intersection(modsOfInterest)
            guard mods == .command else { return event }
            guard
                event.charactersIgnoringModifiers?.lowercased() == "w"
            else { return event }

            // With the find bar up, the key window is its panel and the walk
            // below finds no host — which would quietly turn ⌘W into "close
            // the whole window" mid-search. Fall back to the focus memory,
            // which still names the pane the user was typing in.
            if FindBarPanelController.shared.isPresenting {
                guard TerminalPanes.shared.lastFocusedPaneKind == .shell
                else { return event }
                self.closeFocusedShell.send(())
                return nil
            }

            guard let window = NSApp.keyWindow,
                  let responder = window.firstResponder as? NSView
            else { return event }

            var view: NSView? = responder
            while let v = view {
                if let host = v as? TerminalHostView,
                   host.pane is ShellTerminalPane {
                    self.closeFocusedShell.send(())
                    return nil  // consume the event
                }
                view = v.superview
            }
            return event
        }
    }
}
