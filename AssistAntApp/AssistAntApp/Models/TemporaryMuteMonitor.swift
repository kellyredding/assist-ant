import Combine
import Foundation

/// Publishes the moment the last temporary silence lifts, so the announcement
/// services can replay what it swallowed.
///
/// Before this existed each service watched `MicActivityService` directly and
/// caught up only from a call — leaving the manual mute and away-from-desk
/// with no catch-up at all, and asking every feature for its own copy of the
/// same reasoning. One signal, three subscribers.
///
/// Subscribers may treat the mic as free when this fires. Silence has lifted,
/// so either the mic is genuinely idle or the user has opted out of
/// mic-muting, and `audioGateOpen` reads identically under both.
///
/// Main-thread by expectation rather than annotation, matching the services
/// that subscribe: every input publishes on main.
final class TemporaryMuteMonitor {
    static let shared = TemporaryMuteMonitor()

    /// Emits once each time temporary silence ends.
    let didLift = PassthroughSubject<Void, Never>()

    private var isSilenced: Bool
    private var observers: Set<AnyCancellable> = []

    private init() {
        isSilenced = SettingsManager.shared.settings.isTemporarilySilenced(
            micInUse: MicActivityService.shared.isMicInUse)

        // Each subscription uses its own signal's *emitted* value and reads
        // the other from its holder. `@Published` emits from `willSet`, so
        // reading back the property that is mid-change yields the previous
        // value — the defect that kept the desk nudge from resuming when a
        // call ended. Reading across signals is safe: the one not publishing
        // has not changed.
        MicActivityService.shared.$isMicInUse
            .removeDuplicates()
            .sink { [weak self] inUse in
                self?.update(
                    settings: SettingsManager.shared.settings,
                    micInUse: inUse)
            }
            .store(in: &observers)

        SettingsManager.shared.$settings
            .sink { [weak self] settings in
                self?.update(
                    settings: settings,
                    micInUse: MicActivityService.shared.isMicInUse)
            }
            .store(in: &observers)
    }

    /// Touch the singleton so its subscriptions exist before the first
    /// silence, rather than lazily on whichever read happens to come first.
    func start() {}

    private func update(settings: AppSettings, micInUse: Bool) {
        let silenced = settings.isTemporarilySilenced(micInUse: micInUse)
        defer { isSilenced = silenced }
        guard isSilenced, !silenced else { return }
        didLift.send()
    }
}
