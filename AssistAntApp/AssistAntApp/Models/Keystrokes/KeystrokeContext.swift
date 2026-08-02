import Foundation

/// What was true about the app at the instant the cheat sheet opened.
///
/// Captured once rather than read live, and that is load-bearing: the sheet's
/// own search field takes first responder as it appears, so a live reading of
/// `editableTextFocused` would be true the whole time the sheet is up and
/// every chord row would dim — the exact inverse of the truth. Snapshotting
/// before the overlay mounts keeps the rows describing the surface *behind*
/// the sheet, which is the surface the reader is asking about.
struct KeystrokeContext: Equatable {
    let tab: MainTab
    let readerOpen: Bool
    let hasSelection: Bool
    let terminalPaneFocused: Bool
    let editableTextFocused: Bool
    let findBarOpen: Bool

    /// A resting main window with nothing focused or selected. The value the
    /// model holds before the sheet has ever been opened.
    static let empty = KeystrokeContext(
        tab: .terminal,
        readerOpen: false,
        hasSelection: false,
        terminalPaneFocused: false,
        editableTextFocused: false,
        findBarOpen: false
    )
}
