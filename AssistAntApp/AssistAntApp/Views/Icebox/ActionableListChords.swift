import AppKit

/// Keyboard chords for an actionable batch-selection surface (the Icebox list
/// and the Schedule agenda). Owns the leader-with-timeout state machine that
/// backs the `*` star-commands and the new `a` (action) and `l` (list/kind)
/// leaders, so both panes share one implementation instead of duplicating the
/// monitor. The host installs it while its list is the live surface (onAppear)
/// and removes it on disappear; every handler is gated on "this tab is
/// selected, no reader open, not typing in a text field," matching the reader's
/// own monitor so the two never both act on a keystroke.
///
/// `*` is always available (select-all / clear); the `a` and `l` leaders arm
/// only when a selection exists, and their second key applies a batch action to
/// the whole selection (or opens the add/change-list modal for `ll`). An
/// unrecognized second key cancels the sequence and falls through, so a stray
/// leader never eats the next command.
@MainActor
final class ActionableListChords {
    /// What the controller needs from the host pane, read per event so it
    /// always sees the current snapshot. The Icebox passes `model.groups`; the
    /// Schedule passes `model.allGroups` (flattened across days).
    struct Context {
        let tab: MainTab
        let selection: ActionableSelection
        let groups: () -> [ActionableGroup]
        let collapsed: () -> Set<String>
        let actions: ActionableActions
        let open: (Item) -> Void
    }

    private var monitor: Any?
    private var pendingLeader: Character?            // '*', 'a', or 'l'
    private var leaderTimer: DispatchWorkItem?
    private static let timeout: TimeInterval = 1.0

    func install(_ ctx: Context) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, ctx) ?? event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clearLeader()
    }

    private func handle(_ event: NSEvent, _ ctx: Context) -> NSEvent? {
        guard MainTabNavigator.shared.selectedTab == ctx.tab,
              ItemViewerModel.shared.openItem == nil,
              !(NSApp.keyWindow?.firstResponder is NSTextView)
        else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased()

        // A leader is armed → the second key applies the chord, or cancels and
        // falls through to normal single-key handling.
        if let leader = pendingLeader {
            clearLeader()
            if applyChord(leader: leader, key: chars, ctx) { return nil }
        }

        // Arm a leader. `*` is always available; `a` / `l` need a selection.
        if event.characters == "*" { arm("*"); return nil }
        if ctx.selection.hasSelection, chars == "a" { arm("a"); return nil }
        if ctx.selection.hasSelection, chars == "l" { arm("l"); return nil }

        // Single-key navigation / selection (unchanged from the old monitor).
        switch chars {
        case "j": ctx.selection.moveFocus(by: 1, order: order(ctx)); return nil
        case "k": ctx.selection.moveFocus(by: -1, order: order(ctx)); return nil
        case "x": ctx.selection.toggleSelectedFocused(); return nil
        default: break
        }
        if event.keyCode == 36 || event.keyCode == 76,           // Return / Enter
           let item = ctx.selection.focusedItem(in: ctx.groups()) {
            ctx.open(item); return nil
        }
        return event
    }

    /// Apply a leader+key chord. Returns true when it matched (swallow the key),
    /// false for an unknown second key (cancel the sequence, fall through).
    private func applyChord(leader: Character, key: String?, _ ctx: Context) -> Bool {
        let selected = ctx.selection.selectedItems(in: ctx.groups(),
                                                   collapsed: ctx.collapsed())
        // Complete / icebox actions skip resolved members, mirroring ItemActions.
        let active = selected.filter { $0.resolvedAt == nil }
        switch (leader, key) {
        case ("*", "a"):
            ctx.selection.selectAll(in: ActionableListNavigation.idsInGroup(
                of: ctx.selection.focusedItemID, ctx.groups()))
        case ("*", "n"): ctx.selection.clearSelection()
        case ("a", "d"): _ = ctx.actions.complete(active)
        case ("a", "r"): _ = ctx.actions.reopen(selected)
        case ("a", "i"): _ = ctx.actions.moveToIcebox(active)
        case ("a", "v"): _ = ctx.actions.removeFromIcebox(active)
        case ("l", "t"): _ = ctx.actions.reclassify(selected, .todo)
        case ("l", "r"): _ = ctx.actions.reclassify(selected, .reminder)
        case ("l", "e"): _ = ctx.actions.reclassify(selected, .explore)
        case ("l", "l"): presentListEditor(for: selected, ctx)
        default: return false
        }
        return true
    }

    private func arm(_ leader: Character) {
        pendingLeader = leader
        leaderTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingLeader = nil }
        leaderTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
    }

    private func clearLeader() {
        pendingLeader = nil
        leaderTimer?.cancel()
        leaderTimer = nil
    }

    private func order(_ ctx: Context) -> [String] {
        ActionableListNavigation.visibleIDs(ctx.groups(), collapsed: ctx.collapsed())
    }

    /// `ll`: open the add/change-list editor seeded with the selection's shared
    /// list name (nil when the set spans lists), then apply to all selected —
    /// the same flow as the cluster's kind-menu list item.
    private func presentListEditor(for selected: [Item], _ ctx: Context) {
        guard !selected.isEmpty else { return }
        let names = Set(selected.map { $0.actionableListName })
        let shared = names.count == 1 ? names.first! : nil
        switch ListEditorWindowController.present(currentName: shared) {
        case .cancel: break
        case .save(let name): _ = ctx.actions.setListName(selected, name)
        case .remove: _ = ctx.actions.setListName(selected, nil)
        }
    }
}
