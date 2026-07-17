import SwiftUI

/// Keyboard-navigable desk controls for the Status popover. Renders the same
/// phase-based status line + actions as `DeskStatusView`, but as a focus ring:
/// arrow keys move focus across the pills, Space / Return activates the focused
/// pill, and the focused pill shows an accent ring. (Tab traversal comes free
/// from SwiftUI's focus system.)
///
/// Kept separate from `DeskStatusView` so the sidebar's four mouse-only phase
/// rows stay untouched — one flat, uniformly-focusable list is far simpler to
/// navigate reliably than retrofitting focus state into each of those rows. It
/// drives the same `DeskService` actions, so behavior matches the sidebar.
///
/// Unlike the sidebar it does not reproduce the nudge state's pulsing accent
/// banner: a static status line ("Time to stand") keeps every phase uniform for
/// keyboard use, and the information is identical.
struct DeskControlsView: View {
    var scale: CGFloat = 1
    /// Invoked after any control fires, so the host popover can dismiss.
    var onAction: () -> Void = {}

    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @FocusState private var focused: Int?

    /// A focusable action pill: its label + the action it runs.
    private struct Control {
        let title: String
        let run: () -> Void
    }

    private var phase: DeskTimerPhase {
        settings.settings.desk.timerPhase(at: clock.currentTime)
    }

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 8 * scale) {
                Image(systemName: statusGlyph)
                Text(statusText).lineLimit(1)
            }
            .font(.system(size: 16 * scale))
            .foregroundStyle(.secondary)

            HStack(spacing: 8 * scale) {
                ForEach(Array(controls.enumerated()), id: \.offset) { index, control in
                    pill(control, index: index)
                }
            }
        }
        // Arrow navigation. The focused pill is a descendant, so its unhandled
        // key events bubble to these handlers; Space / Return activate it.
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
        .onAppear { focusPrimary() }
        // Reset focus to the primary action when the phase *kind* changes
        // (counting → nudge → away → …) so the ring never points at a button
        // that just disappeared; unchanged within a phase across minute ticks.
        .onChange(of: phaseKey) { _, _ in focusPrimary() }
    }

    private func pill(_ control: Control, index: Int) -> some View {
        CapsuleActionButton(title: control.title, scale: scale) {
            control.run()
            onAction()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused, equals: index)
        .overlay {
            if focused == index {
                Capsule().stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func focusPrimary() {
        focused = controls.isEmpty ? nil : 0
    }

    private func move(_ delta: Int) {
        guard !controls.isEmpty else { return }
        // First arrow press (no focus yet) lands on the primary rather than
        // jumping past it.
        guard let current = focused else { focused = 0; return }
        focused = (current + delta + controls.count) % controls.count
    }

    private func activate() {
        guard let i = focused, controls.indices.contains(i) else { return }
        controls[i].run()
        onAction()
    }

    // MARK: - Phase → content

    /// Changes whenever the phase *kind* changes, so `onChange` resets focus on
    /// a button-set change but not on every within-phase minute tick.
    private var phaseKey: String {
        switch phase {
        case .inactive: return "inactive"
        case .counting: return "counting"
        case .nudge: return "nudge"
        case .away: return "away"
        }
    }

    /// The phase's ordered actions; index 0 is primary (initial focus). Mirrors
    /// the buttons `DeskStatusView` shows for each phase, in the same order.
    private var controls: [Control] {
        let desk = DeskService.shared
        switch phase {
        case .counting:
            return [
                Control(title: "Switch now") { desk.acknowledgeSwitch() },
                Control(title: "Away from desk") { desk.goAway() },
                Control(title: "Disable timer") { desk.setEnabled(false) },
            ]
        case .nudge:
            return [
                Control(title: "I've switched") { desk.acknowledgeSwitch() },
                Control(title: "Away from desk") { desk.goAway() },
                Control(title: "Disable timer") { desk.setEnabled(false) },
            ]
        case .away:
            return [
                Control(title: "I'm back at my desk") { desk.returnToDesk() },
            ]
        case .inactive:
            return [
                Control(title: "Away from desk") { desk.goAway() },
                Control(title: "Enable timer") { desk.setEnabled(true) },
            ]
        }
    }

    private var statusGlyph: String {
        switch phase {
        case .inactive: return "chair.fill"
        case .counting(_, let position): return deskGlyph(position)
        case .nudge(let from): return deskGlyph(from.opposite)
        case .away: return "figure.walk.departure"
        }
    }

    private var statusText: String {
        switch phase {
        case .inactive:
            return "At your desk"
        case .counting(let remaining, let position):
            let mins = max(1, Int(ceil(remaining / 60)))
            return "\(position.displayName) · switch to "
                + "\(position.opposite.displayName.lowercased()) in \(mins) min"
        case .nudge(let from):
            return "Time to \(from.opposite.verb)"
        case .away:
            return "Away from desk"
        }
    }

    private func deskGlyph(_ position: DeskPosition) -> String {
        position == .sitting ? "figure.seated.side" : "figure.stand"
    }
}
