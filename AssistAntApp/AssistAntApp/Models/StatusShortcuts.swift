import KeyboardShortcuts

/// Global shortcut that summons the Status popover — the main window's status
/// column (clock, timezone, mute state, and the standing-desk controls) floated
/// over whatever app is frontmost, with the desk controls drivable from the
/// keyboard. Recording + persistence is handled by the `KeyboardShortcuts`
/// library (stores to UserDefaults under this name); the app registers the
/// handler (see `StatusPanelController`) and renders the recorder in the
/// Popovers settings tab.
///
/// Starts unset — opt-in, like the non-Ask capture shortcuts. Mirrors
/// `CaptureShortcuts`, with a single name instead of one per kind.
extension KeyboardShortcuts.Name {
    static let statusPopover = Self("statusPopover")
}
