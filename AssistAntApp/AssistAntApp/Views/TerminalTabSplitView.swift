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
