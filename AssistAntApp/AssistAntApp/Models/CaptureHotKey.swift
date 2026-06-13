import AppKit
import Carbon.HIToolbox

// Carbon's InstallEventHandler takes a non-capturing C function pointer, so the
// hotkey action lives in a file-global the trampoline reads.
private var captureHotKeyHandler: (() -> Void)?

private func captureHotKeyTrampoline(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    captureHotKeyHandler?()
    return noErr
}

/// Registers a system-wide hotkey that fires `onTrigger` from any app, even when
/// AssistAnt isn't frontmost. Uses Carbon `RegisterEventHotKey` — no
/// Accessibility permission needed just to register. The combo (⌃⌥⌘P) is a
/// Phase-1 placeholder; it becomes a user setting later.
final class CaptureHotKey {
    private var ref: EventHotKeyRef?
    private var installed = false

    func install(onTrigger: @escaping () -> Void) {
        guard !installed else { return }
        captureHotKeyHandler = onTrigger

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), captureHotKeyTrampoline, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x41434B50), id: 1) // 'ACKP'
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_P), mods, id, GetApplicationEventTarget(), 0, &ref)
        installed = (status == noErr)
        NSLog("CaptureHotKey: RegisterEventHotKey ⌃⌥⌘P status=\(status) (0=ok)")
    }
}
