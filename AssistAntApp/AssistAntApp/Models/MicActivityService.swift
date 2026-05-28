import Combine
import CoreAudio
import Foundation

/// Publishes whether the microphone is currently being captured by any
/// process — the proxy for "on a call" (every call opens the mic).
/// Observes `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
/// default input device, which reports device-running state without
/// opening an input stream, so it needs no microphone permission and
/// raises no TCC prompt.
///
/// **Asymmetric debounce.** In practice the call apps tested hold the
/// mic for the entire call — in-app mute doesn't release it — so a long
/// cooldown to bridge mid-call drops turned out unnecessary. The
/// debounce stays, minimal, just to absorb momentary glitches:
///
/// - Mic ON is applied **immediately** — suppression is the safe
///   direction, and reacting instantly lets the announcer cancel any
///   in-flight chime/speech the moment the mic goes live.
/// - Mic OFF is applied only after the mic stays off for
///   `releaseCooldown` — a brief settle so a one-off blip doesn't flap
///   the state or start an announcement into a gap about to snap shut.
///
/// Keeping it short is safe: once the mic is genuinely off the call
/// can't hear an announcement anyway, so there's no reason to stay
/// suppressed beyond ruling out an instantaneous glitch.
final class MicActivityService: ObservableObject {
    static let shared = MicActivityService()

    /// Debounced "mic is in use" state. ON edge is immediate; OFF edge
    /// trails by `releaseCooldown`.
    @Published private(set) var isMicInUse: Bool = false

    /// How long the mic must stay off before we treat it as released.
    /// In practice call apps hold the mic for the entire call (in-app
    /// mute doesn't release it), so this is just a light debounce
    /// against momentary glitches, not a window that needs to bridge
    /// real mid-call drops. Kept short for a snappy mic-off response.
    private static let releaseCooldown: TimeInterval = 1.0

    private var inputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var offWorkItem: DispatchWorkItem?

    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    func start() {
        attachToCurrentInputDevice()

        // Follow the default input device when it changes (AirPods
        // plugged in, etc.) so the listener stays on the active mic.
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.attachToCurrentInputDevice()
        }
    }

    private func attachToCurrentInputDevice() {
        if inputDeviceID != AudioObjectID(kAudioObjectUnknown),
           let listener = runningListener {
            AudioObjectRemovePropertyListenerBlock(
                inputDeviceID, &runningAddress, DispatchQueue.main, listener
            )
            runningListener = nil
        }

        guard let devID = currentDefaultInputDevice() else { return }
        inputDeviceID = devID
        applyRaw(rawRunning(devID))

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.applyRaw(self.rawRunning(devID))
        }
        runningListener = listener
        AudioObjectAddPropertyListenerBlock(
            devID, &runningAddress, DispatchQueue.main, listener
        )
    }

    private func currentDefaultInputDevice() -> AudioObjectID? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress, 0, nil, &size, &devID
        )
        guard status == noErr, devID != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        return devID
    }

    private func rawRunning(_ devID: AudioObjectID) -> Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            devID, &runningAddress, 0, nil, &size, &running
        )
        return status == noErr && running != 0
    }

    /// Map a raw device-running reading onto the debounced published
    /// state. Runs on the main queue (the listener block and the
    /// initial read are both dispatched there), so `@Published`
    /// mutations are main-thread safe.
    private func applyRaw(_ running: Bool) {
        if running {
            offWorkItem?.cancel()
            offWorkItem = nil
            if !isMicInUse { isMicInUse = true }
        } else {
            // Already pending an off transition — let it ride.
            guard offWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.offWorkItem = nil
                if self.isMicInUse { self.isMicInUse = false }
            }
            offWorkItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.releaseCooldown, execute: item
            )
        }
    }
}
