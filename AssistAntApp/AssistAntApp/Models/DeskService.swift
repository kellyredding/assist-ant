import Foundation

/// Drives the standing-desk timer's state transitions. The timer's
/// data lives in `SettingsManager.shared.settings.desk`; this service
/// owns the writes so the UI, menu bar, and the audio path all go
/// through one place.
///
/// Today the service is purely event-driven (enable/disable,
/// acknowledge) — there is no per-tick work, because the visible
/// countdown/nudge is derived live by the views from
/// `DeskSettings.timerPhase(at:)`. A tick subscription + repeat timer +
/// audio grow here when desk audio lands.
final class DeskService {
    static let shared = DeskService()

    private init() {}

    /// One-time consistency fixup at launch: if the desk was left
    /// enabled but somehow has no start time, start a fresh timer so a
    /// phase can be computed. Normal prefs.json always has a start time
    /// when enabled; this is defense in depth.
    func start() {
        let desk = SettingsManager.shared.settings.desk
        if desk.enabled, desk.positionStartedAt == nil {
            SettingsManager.shared.settings.desk.positionStartedAt = Date()
        }
    }

    /// Toggle the feature. Enabling always starts a *fresh* timer in
    /// the last-known position (sitting by default on first-ever
    /// enable) — no immediate nudge. Disabling leaves the position
    /// remembered; `timerPhase` reports `.inactive` while off, and a
    /// later enable starts fresh.
    func setEnabled(_ enabled: Bool) {
        var desk = SettingsManager.shared.settings.desk
        desk.enabled = enabled
        if enabled {
            desk.positionStartedAt = Date()
        }
        SettingsManager.shared.settings.desk = desk
    }

    /// "I switched" / "Switch now": flip to the opposite position and
    /// start its interval. Clears any pending nudge implicitly (the
    /// new `positionStartedAt` resets the derived phase to counting).
    /// Works from either the counting state (early switch) or the
    /// nudge state (acknowledgment).
    func acknowledgeSwitch() {
        var desk = SettingsManager.shared.settings.desk
        guard desk.enabled else { return }
        desk.currentPosition = desk.currentPosition.opposite
        desk.positionStartedAt = Date()
        SettingsManager.shared.settings.desk = desk
    }
}
