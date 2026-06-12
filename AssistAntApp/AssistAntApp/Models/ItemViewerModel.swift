import AppKit
import SwiftUI

/// The single, app-wide host for the item reader. Every launch site — the
/// Icebox list today, the Schedule agenda and the Today sidebar next — opens an
/// item through here, and the reader is presented once as an overlay above the
/// right-pane tab content (in ContentView) rather than per-pane. Centralizing
/// the open state, the edit session, and the key/Escape handling buys one
/// Escape monitor, one dismissal path, and a reader that floats over whichever
/// tab launched it.
///
/// Opening records the tab the reader sits over and switches to it; leaving
/// that tab (or clicking any tab) closes the reader, so the reader and the
/// selected tab never disagree. Esc collapses a text selection, then cancels an
/// in-progress edit, else closes. The actionable edit session lives here so the
/// reader keeps editing whichever tab it floats over.
@MainActor
final class ItemViewerModel: ObservableObject {
    static let shared = ItemViewerModel()

    /// The item in the reader; nil shows the plain tab content. The key monitor
    /// and the persisted id follow this in lockstep via didSet.
    @Published private(set) var openItem: Item? {
        didSet {
            let isOpen = openItem != nil, wasOpen = oldValue != nil
            if isOpen, !wasOpen {
                installKeyMonitor()
            } else if !isOpen, wasOpen {
                removeKeyMonitor()
            }
            WindowStatePersistence.shared.saveOpenItemId(openItem?.id)
        }
    }

    /// The edit session for actionable items, hosted here (not in a pane) so the
    /// reader keeps working over any tab. Calendar events are read-only and
    /// leave it idle.
    let edit = ActionableEditSession()

    /// The tab the reader sits over. While open this always equals the
    /// navigator's selected tab — a switch away closes the reader.
    private var openedOverTab: MainTab = .agent
    private var keyMonitor: Any?

    private init() {}

    // MARK: - Open / close

    /// Open `item` in the reader over `tab`, switching to that tab first. Used
    /// by every launch site: the Icebox list and Schedule agenda open over their
    /// own tab; the Today sidebar always opens over Schedule.
    func open(_ item: Item, over tab: MainTab) {
        // Record the over-tab before flipping the selection so the tab-change
        // observer recognizes this as the open's own switch and doesn't close.
        openedOverTab = tab
        let navigator = MainTabNavigator.shared
        if navigator.selectedTab != tab { navigator.selectedTab = tab }
        edit.cancel()
        openItem = item
    }

    /// Close the reader, abandoning any in-progress edit.
    func close() {
        edit.cancel()
        openItem = nil
    }

    /// Reflect a post-action item (Done / Move / reclassify / save) back into the
    /// open reader without re-launching it.
    func updateOpenItem(_ item: Item) {
        openItem = item
    }

    /// Close the reader when the user leaves the tab it sits over. The
    /// over-tab guard lets `open(_:over:)` flip the selection without
    /// self-closing.
    func tabChanged(to tab: MainTab) {
        guard openItem != nil, tab != openedOverTab else { return }
        close()
    }

    // MARK: - Edit session (actionable items)

    func beginEdit() {
        guard let item = openItem else { return }
        edit.begin(title: item.title, body: item.body ?? "")
    }

    func cancelEdit() { edit.cancel() }

    func saveEdit() {
        guard let item = openItem, edit.canSave else { return }
        edit.isSaving = true
        let title = edit.title, body = edit.body
        // The store write is synchronous; defer so the spinner paints, then
        // persist, hand the refreshed item back, and drop to the reader.
        Task { @MainActor in
            if let updated = IceboxModel.shared.setTitleAndBody(
                item, title: title, body: body
            ) {
                openItem = updated
            }
            edit.finishSaving()
        }
    }

    // MARK: - Restore

    /// Reopen the reader saved before the last quit, if its item still exists.
    /// Called once the window is up (ContentView.onAppear), by which point the
    /// selected tab is already restored — the reader sits over it.
    func restoreIfNeeded() {
        guard openItem == nil,
              let id = WindowStatePersistence.shared.loadOpenItemId()
        else { return }
        guard let item = try? GRDBItemStore.shared.fetch(id: id),
              item.deletedAt == nil
        else {
            WindowStatePersistence.shared.saveOpenItemId(nil)
            return
        }
        openedOverTab = MainTabNavigator.shared.selectedTab
        openItem = item
    }

    // MARK: - Key monitor

    // While the reader is open, own only its own commands. Esc collapses a text
    // selection first, then cancels an edit or closes the reader. ⌘↵ toggles
    // edit / saves and Tab swaps title⇄body — actionable items only (calendar
    // events are read-only). Navigation shortcuts are left alone: the View-menu
    // nav items disable themselves while a text field is focused
    // (MenuActions.editableTextIsFocused), so ⌘←/→, ⌘⇧←/→, and ⌥-motion reach
    // the editor with their native bindings intact.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let item = self.openItem else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let key = event.keyCode

            if key == 53 {                                  // Escape
                // A non-empty selection swallows the first Escape by collapsing
                // to a caret; only a selection-free Escape exits / closes.
                // Applies to the editable fields and the selectable body alike.
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
                   tv.selectedRange().length > 0 {
                    tv.setSelectedRange(
                        NSRange(location: tv.selectedRange().location, length: 0))
                    return nil
                }
                if self.edit.isEditing {
                    self.cancelEdit()
                } else {
                    DispatchQueue.main.async { self.close() }
                }
                return nil
            }

            // ⌘↵ / Tab are edit commands; calendar events never edit.
            guard Self.isActionable(item) else { return event }

            if self.edit.isEditing {
                if cmd, key == 36 || key == 76 {            // ⌘↵ → save
                    self.saveEdit()
                    return nil
                }
                if key == 48 {                              // Tab / ⇧Tab → swap field
                    self.edit.focus = (self.edit.focus == .title) ? .body : .title
                    return nil
                }
                return event
            } else {
                if cmd, key == 36 || key == 76 {            // ⌘↵ → enter edit
                    self.beginEdit()
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Calendar events are read-only; everything else (todo / reminder /
    /// explore) is an editable actionable item.
    private static func isActionable(_ item: Item) -> Bool {
        if case .calendar = item.typeData { return false }
        return true
    }
}
