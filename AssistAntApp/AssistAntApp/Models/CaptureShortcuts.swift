import KeyboardShortcuts

/// Global capture shortcuts, one per `CaptureKind`. Each summons the Quick
/// Capture popover preset to its kind (see `CapturePanelController.summon`).
/// Recording + persistence is handled by the `KeyboardShortcuts` library
/// (stores to UserDefaults under these names); the app only registers the
/// handlers and renders the recorder controls in the Capture settings tab.
///
/// Ask carries the historical default (⌃⌥⌘P) so the summon that shipped with
/// the popover keeps working out of the box; the other kinds start unset and
/// are opt-in via the settings tab.
extension KeyboardShortcuts.Name {
    static let captureAsk = Self(
        "captureAsk",
        default: .init(.p, modifiers: [.control, .option, .command]))
    static let captureTodo = Self("captureTodo")
    static let captureReminder = Self("captureReminder")
    static let captureExplore = Self("captureExplore")
    static let captureTask = Self("captureTask")

    /// The shortcut name that summons a given kind — keeps the controller's
    /// registration loop and any kind→name lookups in one place.
    static func capture(for kind: CaptureKind) -> KeyboardShortcuts.Name {
        switch kind {
        case .ask: return .captureAsk
        case .todo: return .captureTodo
        case .reminder: return .captureReminder
        case .explore: return .captureExplore
        case .task: return .captureTask
        }
    }
}
