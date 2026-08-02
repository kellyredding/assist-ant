import Foundation

extension AppSettings {
    /// Is audio silenced right now for a reason a catch-up should stand in
    /// for? Convenience over `TemporaryMuteRule` for the callers that already
    /// hold a settings snapshot.
    ///
    /// Separate from the rule's own file so that file stays free of this type,
    /// whose terminal fields reach into Galactic and would drag the whole
    /// package into the smoke target alongside them.
    func isTemporarilySilenced(micInUse: Bool) -> Bool {
        TemporaryMuteRule.isSilenced(
            muteWhileMicInUse: muteWhileMicInUse,
            micInUse: micInUse,
            isAway: desk.isAwayActive,
            isManuallyMuted: isMuted
        )
    }
}
