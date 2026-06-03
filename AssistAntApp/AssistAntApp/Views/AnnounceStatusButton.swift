import SwiftUI
import AppKit

/// The speaker icon + click affordance, displayed inline after the
/// time in `ClockView`. Renders an SF Symbol whose glyph encodes the
/// announcement system's current state (disabled / scheduled / active
/// / muted). The clickable states overlay a pointing-hand affordance on
/// the glyph (`pointerButton` / `pointerMenu`) so a pointer cursor shows
/// on hover; the dropdowns are native menus, since the cursor overlay
/// owns the click and a SwiftUI `Menu` can't share it. Click behavior
/// depends on state:
///
/// - Disabled → opens Settings with the Time tab pre-selected, so
///   the user can flip Enable on without rummaging through tabs.
/// - Scheduled → also opens Settings to the Time tab. Announcements
///   are already silent-by-schedule right now, so offering "mute"
///   would be pointless; the useful action is jumping to the
///   schedule to review/adjust it.
/// - Active → pops up a menu of mute durations.
/// - Muted by timer / mic / away → non-interactive (no pointer cursor).
///   A timed mute is cleared from the "Unmute now" button on the clock's
///   status row; mic and away clear themselves.
///
/// Re-renders on minute boundaries (driven by `ClockService`), on
/// settings changes (driven by `SettingsManager`), and on mic
/// engage/free (driven by `MicActivityService`), so state transitions
/// happen automatically as schedule windows open/close, the timed
/// mute expires, and calls start/end.
struct AnnounceStatusButton: View {
    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var mic = MicActivityService.shared

    /// Rendered height of the speaker glyph — sized to sit as a visual
    /// peer to the large clock it lives beside (see ClockView's 96pt
    /// time). Applied via `.resizable().scaledToFit().frame(height:)`
    /// on the Image so it renders at an explicit size regardless of any
    /// ambient font.
    private let iconHeight: CGFloat = 56

    /// Fixed slot width so swapping between glyphs of different widths
    /// (slash / fill / wave.3.fill) doesn't shift the centered time
    /// beside it. Sized to fit the widest glyph (speaker.wave.3.fill)
    /// at `iconHeight`.
    private let slotWidth: CGFloat = 96

    private var state: AnnouncementIconState {
        settings.settings.iconState(
            at: clock.currentTime,
            micInUse: mic.isMicInUse
        )
    }

    /// Color per state, applied via `.foregroundStyle` on the glyph.
    /// The glyph renders as a plain Image (no Button/Menu wrapper), so
    /// the tint applies directly. The muted states are system orange to
    /// match the ClockView status row so the two read as one connected
    /// indicator.
    private var iconTint: Color {
        switch state {
        case .disabled:                 return .secondary.opacity(0.5)
        case .scheduled, .active:       return .primary
        case .mutedByTimer, .mutedByMic, .mutedByAway: return .orange
        }
    }

    var body: some View {
        Group {
            switch state {
            case .disabled, .scheduled:
                glyph.pointerButton { openSettings() }
            case .active:
                glyph.pointerMenu { muteDurationsMenu() }
            case .mutedByTimer, .mutedByMic, .mutedByAway:
                // Muted: informational, no pointer cursor. A timed mute is
                // cleared from the "Unmute now" button on the ClockView
                // status row; mic and away clear themselves.
                glyph
            }
        }
        .frame(width: slotWidth)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// The sized speaker glyph. `.resizable().scaledToFit()
    /// .frame(height:)` forces a concrete render size. The interactive
    /// states overlay a click-owning pointer affordance (`pointerButton`
    /// / `pointerMenu`) on this glyph rather than wrapping it in a SwiftUI
    /// Button or Menu, so the pointing-hand cursor shows reliably on
    /// hover. `.foregroundStyle` applies the per-state tint.
    private var glyph: some View {
        Image(systemName: state.sfSymbol)
            .resizable()
            .scaledToFit()
            .frame(height: iconHeight)
            .foregroundStyle(iconTint)
    }

    /// Open Settings to the Time tab — the useful action for both the
    /// disabled and scheduled states (enable announcements, or review the
    /// schedule). Deferred to the next run-loop tick: showPreferences
    /// calls NSApp.runModal(for:), which spins up a nested modal event
    /// loop; invoking it synchronously inside the click handler nests it
    /// in the still-in-flight mouse event and starves the modal window of
    /// events (it opens but won't take clicks). The hop matches the clean
    /// main-loop pass the menu-bar and ⌘, paths already use.
    private func openSettings() {
        DispatchQueue.main.async {
            PreferencesWindowController.showPreferences(initialTab: .time)
        }
    }

    /// Native pop-up of mute durations, shown from the active state. Built
    /// as an NSMenu rather than a SwiftUI Menu so the click-owning pointer
    /// overlay can present it (see `glyph`).
    private func muteDurationsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem.sectionHeader(title: "Mute announcements for")
        )
        for duration in MuteDuration.allCases {
            menu.addItem(ClosureMenuItem(title: duration.displayName) {
                MuteController.mute(for: duration)
            })
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure when selected, so the speaker
/// icon's native pop-up menus can be built inline without a separate
/// target/selector object.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() { handler() }
}
