import SwiftUI

/// The speaker icon + click affordance, displayed inline after the
/// time in `ClockView`. Renders an SF Symbol whose glyph encodes the
/// announcement system's current state (disabled / scheduled / active
/// / muted). The clickable states overlay a pointing-hand affordance on
/// the glyph (`pointerButton`) so a pointer cursor shows on hover. Click
/// behavior depends on state:
///
/// - Disabled → opens Settings with the Time tab pre-selected, so
///   the user can flip Enable on without rummaging through tabs.
/// - Scheduled → also opens Settings to the Time tab. Announcements
///   are already silent-by-schedule right now, so offering "mute"
///   would be pointless; the useful action is jumping to the
///   schedule to review/adjust it.
/// - Active → click mutes (open-ended) until unmuted.
/// - Muted manually → click unmutes (the "Unmute now" button on the
///   clock's status row does the same thing).
/// - Muted by mic / away → non-interactive (no pointer cursor); these
///   clear themselves when the mic frees or you return to the desk.
///
/// Re-renders on minute boundaries (driven by `ClockService`), on
/// settings changes (driven by `SettingsManager`), and on mic
/// engage/free (driven by `MicActivityService`), so state transitions
/// happen automatically as schedule windows open/close, the mute
/// toggles, and calls start/end.
struct AnnounceStatusButton: View {
    /// Scale factor applied to the glyph height + slot width so the icon
    /// tracks the adaptively-scaled clock it sits beside. 1 = natural size.
    var scale: CGFloat = 1

    @ObservedObject private var clock = ClockService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var mic = MicActivityService.shared

    /// Rendered height of the speaker glyph — sized to sit as a visual
    /// peer to the large clock it lives beside (see ClockView's 96pt
    /// time). Applied via `.resizable().scaledToFit().frame(height:)`
    /// on the Image so it renders at an explicit size regardless of any
    /// ambient font.
    private var iconHeight: CGFloat { 56 * scale }

    /// Fixed slot width so swapping between glyphs of different widths
    /// (slash / fill / wave.3.fill) doesn't shift the centered time
    /// beside it. Sized to fit the widest glyph (speaker.wave.3.fill)
    /// at `iconHeight`.
    private var slotWidth: CGFloat { 96 * scale }

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
        case .mutedManually, .mutedByMic, .mutedByAway: return .orange
        }
    }

    var body: some View {
        Group {
            switch state {
            case .disabled, .scheduled:
                ClickableGlyph(symbol: state.sfSymbol, height: iconHeight,
                               tint: iconTint) { openSettings() }
            case .active:
                ClickableGlyph(symbol: state.sfSymbol, height: iconHeight,
                               tint: iconTint) { MuteController.mute() }
            case .mutedManually:
                ClickableGlyph(symbol: state.sfSymbol, height: iconHeight,
                               tint: iconTint) { MuteController.unmute() }
            case .mutedByMic, .mutedByAway:
                // Mic-mute clears when the mic frees; away clears when you
                // return to your desk — nothing to act on here, so the
                // icon is purely informational (no pointer cursor).
                glyph
            }
        }
        .frame(width: slotWidth)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// The sized speaker glyph. `.resizable().scaledToFit()
    /// .frame(height:)` forces a concrete render size. The interactive
    /// states overlay a click-owning pointer affordance (`pointerButton`)
    /// on this glyph rather than wrapping it in a SwiftUI Button or Menu,
    /// so the pointing-hand cursor shows reliably on hover.
    /// `.foregroundStyle` applies the per-state tint.
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
}

/// The speaker glyph as a dedicated clickable affordance. A standalone
/// `View` (rather than an inline `glyph.pointerButton`) so the
/// pointerButton overlay keeps a stable identity across
/// AnnounceStatusButton's frequent re-renders — it re-renders every minute
/// on the clock tick, and inlining the overlay there left it non-topmost,
/// so the pointing-hand cursor stopped showing while hover still
/// registered.
private struct ClickableGlyph: View {
    let symbol: String
    let height: CGFloat
    let tint: Color
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(tint)
            .pointerButton(action: action)
    }
}
