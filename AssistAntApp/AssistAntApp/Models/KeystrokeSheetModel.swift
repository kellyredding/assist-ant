import AppKit
import Combine
import Foundation
import Galactic

/// Presentation state for the ⌘/ cheat sheet, and the one place that reads
/// live app state into a `KeystrokeContext`.
///
/// The snapshot is taken *before* the overlay mounts, which is the whole
/// reason this is a model rather than view state: the sheet's own search field
/// takes first responder as it appears, so anything reading focus afterwards
/// would see "the user is typing" and dim every chord row.
@MainActor
final class KeystrokeSheetModel: ObservableObject {
    static let shared = KeystrokeSheetModel()

    @Published private(set) var isPresented = false
    /// What was true when the sheet opened. Meaningless while closed.
    @Published private(set) var context: KeystrokeContext = .empty

    /// Live only while the sheet is up. See `installEscapeMonitor`.
    private var escapeMonitor: Any?

    private init() {}

    /// Open with a fresh snapshot, or close if already open — so the same
    /// keystroke that summons the sheet dismisses it.
    func toggle() {
        if isPresented {
            dismiss()
        } else {
            context = Self.captureContext()
            isPresented = true
            installEscapeMonitor()
        }
    }

    func dismiss() {
        isPresented = false
        removeEscapeMonitor()
    }

    /// Escape closes the sheet.
    ///
    /// A local event monitor rather than `.onExitCommand` on the view: the
    /// overlay floats over surfaces that hold first responder and claim
    /// Escape for themselves — the agent terminal swallows it outright — so a
    /// SwiftUI handler never sees the key. Galactic's scrollback overlay
    /// reaches for a monitor over the same surface for the same reason.
    ///
    /// Installed only while presented, so Escape keeps its ordinary meaning
    /// everywhere else in the app.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.isPresented, event.keyCode == 53 else {
                return event
            }
            self.dismiss()
            return nil   // consumed: it must not also reach the terminal
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Read the surface the user is looking at.
    ///
    /// Focus questions are delegated to `MenuActions`, which already answers
    /// them for menu validation — asking the same question two ways is how the
    /// sheet would end up disagreeing with which commands are actually live.
    private static func captureContext() -> KeystrokeContext {
        let tab = MainTabNavigator.shared.selectedTab
        return KeystrokeContext(
            tab: tab,
            readerOpen: ItemViewerModel.shared.openItem != nil,
            hasSelection: hasSelection(on: tab),
            terminalPaneFocused: MenuActions.agentTerminalIsFocused(),
            editableTextFocused: MenuActions.editableTextIsFocused(),
            findBarOpen: FindBarPanelController.shared.isPresenting
        )
    }

    /// Whether the surface on screen has anything selected.
    ///
    /// Each list surface owns its own selection, so this is a question only
    /// the active tab can answer — and the tabs that install no chords have no
    /// selection to speak of, which is why they answer false rather than
    /// reaching for a shared one that does not exist.
    private static func hasSelection(on tab: MainTab) -> Bool {
        switch tab {
        case .icebox: return IceboxModel.shared.selection.hasSelection
        case .schedule: return ScheduleAgendaModel.shared.selection.hasSelection
        case .trash: return TrashModel.shared.selection.hasSelection
        case .terminal, .tasks: return false
        }
    }
}
