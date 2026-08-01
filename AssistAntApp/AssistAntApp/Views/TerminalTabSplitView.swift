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

    /// How far the divider may travel. The shared window, so the drag and the
    /// configurable default cannot disagree about it — and so a change to it is
    /// made once.
    private static let bounds = PaneSplitBounds.standard

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
                                state.split.beginDrag()
                            },
                            onBarDrag: { delta in
                                state.split.updateDrag(
                                    cursorDeltaY: delta,
                                    totalHeight: totalHeight,
                                    bounds: Self.bounds
                                )
                            },
                            onBarDragEnded: {
                                state.split.commitDrag()
                            },
                            onBarDoubleClick: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.split.ratio = Self.configuredTopRatio()
                                }
                            }
                        )
                        .frame(height: totalHeight - topHeight)
                    }
                }

                // Ghost line, shown only mid-drag. It tracks the cursor live
                // so neither terminal buffer reflows until the drag commits.
                if let preview = state.split.previewRatio,
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
                TerminalPanes.shared.restoreFocus(kind: .shell)
            } else {
                state.openShell()
            }
        }
        .onReceive(TerminalTabCommands.shared.focusSession) { _ in
            // Through the registry, not the backend: with a scrollback open
            // on the session pane, focusing the backend would land on the
            // live terminal hidden behind the overlay. Galaxy's own ⌘T goes
            // straight to the backend and has exactly that bug.
            TerminalPanes.shared.restoreFocus(kind: .session)
        }
        .onReceive(TerminalTabCommands.shared.closeFocusedShell) { _ in
            guard let pane = state.shellPane else { return }
            // Gate the close on a confirmation when the shell's scrollback
            // holds notes. The helper closes straight through when there is
            // nothing to lose, so the common case is unchanged.
            AppDelegate.shared?.confirmAndCloseShellPane {
                pane.requestClose()
            }
        }
    }

    private func clampedTopHeight(totalHeight: CGFloat) -> CGFloat {
        return totalHeight * state.split.clamped(to: Self.bounds)
    }

    /// Top-pane fraction derived from the configured default shell height.
    /// Clamped to the same window the drag enforces, so the setting can never
    /// disagree with live drag bounds. Used on shell open and on reset.
    static func configuredTopRatio() -> CGFloat {
        PaneSplitRatio.topRatio(
            forBottomRatio: SettingsManager.shared.settings
                .shellDefaultHeightRatio,
            within: bounds
        )
    }
}

/// Mutable split state — ratio, the shell pane, and drag-preview bookkeeping.
/// Held as a `@StateObject` so it survives re-renders but is rebuilt cleanly
/// if the view's identity changes.
final class SplitState: ObservableObject {
    /// Where the divider sits, committed and mid-drag.
    ///
    /// One published value rather than three properties kept in step by hand,
    /// so every mutation of it announces itself to the view.
    @Published var split = PaneSplitRatio()

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
        split.ratio = TerminalTabSplitView.configuredTopRatio()
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
            TerminalPanes.shared.restoreFocus(kind: .session)
        }
    }
}

/// App-wide ⌘W interceptor for the Terminal tab's shell pane.
///
/// Consumes ⌘W only when focus sits in the shell pane. Every other ⌘W passes
/// through to Close Window unchanged. The command carries no session — there is
/// one — so it addresses the only split there is.
///
/// Still app-side because the walk below names this app's host and pane types.
/// It moves once those do; the command it sends, and the ⌘W match itself,
/// already come from the engine.
final class ShellCloseKeyMonitor {
    static let shared = ShellCloseKeyMonitor()

    /// Held for the life of the app so the monitor is never torn down.
    private var monitor: Any?

    private init() {
        install()
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard TerminalTabKeyCommand.isCloseWindow(event) else {
                return event
            }

            // With the find bar up, the key window is its panel and the walk
            // below finds no host — which would quietly turn ⌘W into "close
            // the whole window" mid-search. Fall back to the focus memory,
            // which still names the pane the user was typing in.
            if FindBarPanelController.shared.isPresenting {
                guard TerminalPanes.shared.lastFocusedPaneKind == .shell
                else { return event }
                TerminalTabCommands.shared.closeFocusedShell.send(nil)
                return nil
            }

            guard let window = NSApp.keyWindow,
                  let responder = window.firstResponder as? NSView
            else { return event }

            var view: NSView? = responder
            while let v = view {
                if let host = v as? TerminalHostView,
                   host.pane is ShellTerminalPane {
                    TerminalTabCommands.shared.closeFocusedShell.send(nil)
                    return nil  // consume the event
                }
                view = v.superview
            }
            return event
        }
    }
}
