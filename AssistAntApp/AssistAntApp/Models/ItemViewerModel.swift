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
    /// The `a` / `l` leader sequence for the reader's keyboard chords.
    private let leader = LeaderChord()

    private init() {}

    // MARK: - Open / close

    /// Open `item` in the reader over `tab`, switching to that tab first. Used
    /// by every launch site: the Icebox list and Schedule agenda open over their
    /// own tab; the Today sidebar always opens over Schedule.
    func open(_ item: Item, over tab: MainTab) {
        // The reader covers the rows it floats over — dismiss any hover tooltip
        // so it can't strand on top of the reader.
        ItemTooltipController.shared.hideNow()
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
        // Drop first responder off the reader's selectable (read-only) body
        // before SwiftUI tears it down — otherwise it can linger as the window's
        // first responder, and a stale text-view responder makes the list chord
        // monitor bail on every key (→ the no-op beep on the lists).
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
        openItem = nil
    }

    /// Reflect a post-action item (Done / Move / reclassify / save) back into the
    /// open reader without re-launching it.
    func updateOpenItem(_ item: Item) {
        openItem = item
    }

    /// The action-cluster mutations, routed to the model for the tab the reader
    /// floats over — mirroring `saveEdit`. The cluster buttons and the reader
    /// chords both go through this, so a Schedule-hosted reader updates the
    /// agenda snapshot and an Icebox-hosted one the icebox.
    var actions: ActionableActions {
        switch openedOverTab {
        case .schedule: return ScheduleAgendaModel.shared.actions
        case .trash:    return TrashModel.shared.actions
        default: return IceboxModel.shared.actions
        }
    }

    /// True while the reader is presented over the Trash tab — the cluster stays
    /// the trash controls (Put back ⇄ Delete) even after a put-back clears the
    /// tombstone, so the action can be undone.
    var isTrashReader: Bool { openedOverTab == .trash }

    /// Close the reader when the user leaves the tab it sits over. The
    /// over-tab guard lets `open(_:over:)` flip the selection without
    /// self-closing.
    func tabChanged(to tab: MainTab) {
        guard openItem != nil, tab != openedOverTab else { return }
        close()
    }

    // MARK: - Edit session (actionable items)

    func beginEdit() {
        // Read-only in the Trash tab (even a put-back item) and for any deleted item.
        guard let item = openItem, item.deletedAt == nil, openedOverTab != .trash else { return }
        edit.begin(title: item.title, body: item.body ?? "")
    }

    func cancelEdit() { edit.cancel() }

    func saveEdit() {
        guard let item = openItem, edit.canSave else { return }
        edit.isSaving = true
        let title = edit.title, body = edit.body
        // The store write is synchronous; defer so the spinner paints, then
        // persist via whichever surface the reader floats over so that list's
        // snapshot updates the row in place, hand the refreshed item back, and
        // drop to the reader.
        Task { @MainActor in
            let updated: Item?
            switch openedOverTab {
            case .schedule:
                updated = ScheduleAgendaModel.shared.setTitleAndBody(
                    item, title: title, body: body)
            case .trash:
                updated = TrashModel.shared.setTitleAndBody(
                    item, title: title, body: body)
            default:
                updated = IceboxModel.shared.setTitleAndBody(
                    item, title: title, body: body)
            }
            if let updated { openItem = updated }
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
                    if item.deletedAt == nil, self.openedOverTab != .trash { self.beginEdit() }
                    return nil
                }
                // a / l leaders + j/k navigation on the open item (the "batch"
                // is this single item). Plain letters only — never while a
                // modifier is down, so ⌘-shortcuts pass through.
                if !cmd, self.handleNavOrChord(event) { return nil }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        leader.clear()
    }

    // MARK: - Keyboard chords + navigation (single open item)

    /// Arm/apply the a/l leader chords, or step j/k through the source list,
    /// against the open reader. Returns true when the key was consumed; false to
    /// let it fall through. The pending leader is checked first (its second key,
    /// or a cancel), then arming, then j/k. Unlike `ActionableListChords` this
    /// does NOT bail when a text view holds first responder — the reader's
    /// read-only body is a selectable NSTextView that is legitimately focused;
    /// `edit.isEditing` (checked by the caller) is the real gate.
    private func handleNavOrChord(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if let armed = leader.take() {
            return applyChord(leader: armed, key: chars)
        }
        if chars == "a" { leader.arm("a"); return true }
        if chars == "l" { leader.arm("l"); return true }
        switch chars {
        case "j": stepOpenItem(by: 1); return true
        case "k": stepOpenItem(by: -1); return true
        default: return false
        }
    }

    /// Apply a leader+key chord to the open item, reflecting the result back into
    /// the reader. Returns true when it matched, false for an unknown second key
    /// (cancel: the leader is already cleared, the key falls through). Complete /
    /// icebox skip a resolved item, mirroring the cluster + list chords.
    private func applyChord(leader leaderKey: Character, key: String?) -> Bool {
        guard let item = openItem else { return false }
        let one = [item]
        let active = item.resolvedAt == nil ? one : []
        let a = actions
        let updated: [Item]
        switch (leaderKey, key) {
        case ("a", "d") where openedOverTab == .trash:
            updated = a.delete(item.isSynced ? [] : one)   // trash re-delete
        case ("a", "d"): updated = a.complete(active)
        case ("a", "r"): updated = a.reopen(one)
        case ("a", "i"): updated = a.moveToIcebox(active)
        case ("a", "v"): updated = a.removeFromIcebox(active)
        case ("a", "c"): ItemClipboard.copy(one); return true   // read-only; nothing to reflect
        case ("a", "l"): ItemLinks.urls(for: one).forEach { NSWorkspace.shared.open($0) }; return true
        case ("a", "p") where openedOverTab == .trash:
            updated = a.putBack(item.isSynced ? [] : one)   // synced: sync owns it (no-op)
        case ("l", "t"): updated = a.reclassify(one, .todo)
        case ("l", "r"): updated = a.reclassify(one, .reminder)
        case ("l", "e"): updated = a.reclassify(one, .explore)
        case ("l", "l"): presentListEditor(for: item); return true
        case ("l", "d") where openedOverTab != .trash:
            updated = a.delete(item.isSynced ? [] : one)   // synced: sync owns it (no-op)
        case ("l", "p") where openedOverTab != .trash:
            updated = a.putBack(item.isSynced ? [] : one)
        default: return false
        }
        if let u = updated.first { updateOpenItem(u) }
        return true
    }

    /// `ll`: open the add/change-list editor seeded with the item's list name,
    /// then apply — the same flow as the cluster's kind-menu list item and the
    /// list controller's `ll`. Reflects the result back into the reader.
    private func presentListEditor(for item: Item) {
        switch ListEditorWindowController.present(currentName: item.actionableListName) {
        case .cancel: break
        case .save(let name):
            if let u = actions.setListName([item], name).first { updateOpenItem(u) }
        case .remove:
            if let u = actions.setListName([item], nil).first { updateOpenItem(u) }
        }
    }

    /// j/k: step to the previous/next item in the list the reader was opened over
    /// (Icebox or Schedule) and re-open it in place, so the reader walks the
    /// source list. Also moves that list's keyboard focus, so closing the reader
    /// leaves it on the last-viewed row. No-op at the ends (step clamps), when the
    /// open item isn't in the source list (e.g. an unscheduled item opened over
    /// the Schedule, which lists only scheduled items), or when the neighbor
    /// can't be fetched.
    private func stepOpenItem(by delta: Int) {
        guard let item = openItem else { return }
        let source = sourceList()
        let order = ActionableListNavigation.visibleIDs(
            source.groups, collapsed: source.collapsed)
        guard order.contains(item.id),
              let nextID = ActionableListNavigation.step(from: item.id, by: delta, in: order),
              nextID != item.id,
              let next = try? GRDBItemStore.shared.fetch(id: nextID)
        else { return }
        source.selection.focus(nextID)
        updateOpenItem(next)
    }

    /// The list the reader floats over, for j/k navigation — same routing as
    /// `actions` / `saveEdit`. Schedule navigates its actionables across all
    /// loaded days (`allGroups`); the Icebox its grouped iceboxed items.
    private func sourceList()
        -> (groups: [ActionableGroup], selection: ActionableSelection, collapsed: Set<String>) {
        switch openedOverTab {
        case .schedule:
            let m = ScheduleAgendaModel.shared
            return (m.allGroups, m.selection, m.collapsedLists)
        case .trash:
            let m = TrashModel.shared
            return (m.groups, m.selection, m.collapsedLists)
        default:
            let m = IceboxModel.shared
            return (m.groups, m.selection, m.collapsedLists)
        }
    }

    /// Calendar events are read-only; everything else (todo / reminder /
    /// explore) is an editable actionable item.
    private static func isActionable(_ item: Item) -> Bool {
        if case .calendar = item.typeData { return false }
        return true
    }
}
