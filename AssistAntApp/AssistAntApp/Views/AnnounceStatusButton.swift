import SwiftUI

/// The 4-state speaker icon + click menu, displayed inline after the
/// time in `ClockView`. Renders an SF Symbol whose glyph encodes the
/// announcement system's current state (disabled / scheduled / active
/// / muted). Click behavior depends on state:
///
/// - Disabled → opens Settings with the Time tab pre-selected, so
///   the user can flip Enable on without rummaging through tabs.
/// - Scheduled → also opens Settings to the Time tab. Announcements
///   are already silent-by-schedule right now, so offering "mute"
///   would be pointless; the useful action is jumping to the
///   schedule to review/adjust it.
/// - Active → shows a menu of mute durations.
/// - Muted by timer → shows a menu with Unmute Now.
/// - Muted by mic → non-interactive (the mic-mute clears itself when
///   the mic frees, so there's nothing to act on).
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
    /// on the Image rather than `.font(size:)`, because the
    /// borderlessButton menu style ignores an ambient font on its
    /// label; a resizable image sizes to its frame regardless.
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
    /// Works now that the menus use `.buttonStyle(.plain)` (the old
    /// `.borderlessButton` style ignored foregroundStyle on its
    /// label). Both muted states are system orange to match the
    /// ClockView status row so the two read as one connected indicator.
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
                openSettingsButton
            case .active:
                muteMenu
            case .mutedByTimer:
                unmuteMenu
            case .mutedByMic, .mutedByAway:
                // Mic-mute clears when the mic frees; away clears when
                // you return to your desk — nothing to act on here, so
                // the icon is purely informational.
                glyph
            }
        }
        .frame(width: slotWidth)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// The sized speaker glyph. `.resizable().scaledToFit()
    /// .frame(height:)` forces a concrete render size, and the menus
    /// that wrap it use `.menuStyle(.button)` + `.buttonStyle(.plain)`
    /// so the label renders at this intrinsic size rather than being
    /// clamped to standard control metrics (which is what
    /// `.borderlessButton` does — it caps both size and color).
    /// `.foregroundStyle` applies the per-state tint; plain button
    /// style respects it.
    private var glyph: some View {
        Image(systemName: state.sfSymbol)
            .resizable()
            .scaledToFit()
            .frame(height: iconHeight)
            .foregroundStyle(iconTint)
    }

    /// Used by both the disabled and scheduled states — in both, the
    /// useful action is opening Settings to the Time tab (to enable
    /// announcements, or to review/adjust the schedule). The glyph
    /// and color differ per state via `glyph` / `iconTint`.
    private var openSettingsButton: some View {
        Button {
            // Defer to the next run-loop tick. showPreferences calls
            // NSApp.runModal(for:), which spins up a nested modal
            // event loop; invoking it synchronously inside this
            // SwiftUI click handler nests it inside the still-in-flight
            // mouse-up event and starves the modal window of events
            // (it opens but won't take clicks). The menu-bar and ⌘,
            // paths reach showPreferences via a menu-item selector /
            // NotificationCenter post, which already run on a clean
            // main-loop pass; this async hop matches that.
            DispatchQueue.main.async {
                PreferencesWindowController.showPreferences(initialTab: .time)
            }
        } label: {
            glyph
        }
        .buttonStyle(.plain)
    }

    private var muteMenu: some View {
        Menu {
            Section("Mute announcements for") {
                ForEach(MuteDuration.allCases) { duration in
                    Button(duration.displayName) {
                        MuteController.mute(for: duration)
                    }
                }
            }
        } label: {
            glyph
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var unmuteMenu: some View {
        Menu {
            // No "Muted until X" header here — the ClockView status
            // row directly below the clock already shows it, so a
            // header in this dropdown would be redundant. Just the
            // unmute action.
            Button("Unmute now") {
                MuteController.unmute()
            }
        } label: {
            glyph
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
