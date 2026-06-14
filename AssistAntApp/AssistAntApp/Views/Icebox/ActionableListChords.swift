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
    private let leader = LeaderChord()               // '*', 'a', or 'l'

    func install(_ ctx: Context) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `handle` returns nil to CONSUME a key. Do NOT fall back to `event`
            // on a nil return — that revived every consumed keystroke (j/k beeped
            // on the lists and bled into the agent PTY). Only a deallocated self
            // passes the event through.
            guard let self else { return event }
            return self.handle(event, ctx)
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        leader.clear()
    }

    private func handle(_ event: NSEvent, _ ctx: Context) -> NSEvent? {
        // Bail only for an EDITABLE text view (a focused field), not any text
        // view: a read-only selectable body — e.g. the reader's, which can stay
        // the window's first responder after the reader closes — must not block
        // the list chords, or every key (j/k included) bubbles to the no-op beep.
        guard MainTabNavigator.shared.selectedTab == ctx.tab,
              ItemViewerModel.shared.openItem == nil,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
        else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased()

        // A leader is armed → the second key applies the chord, or cancels and
        // falls through to normal single-key handling.
        if let armed = leader.take() {
            if applyChord(leader: armed, key: chars, ctx) { return nil }
        }

        // Arm a leader. `*` is always available; `a` / `l` need a selection.
        if event.characters == "*" { leader.arm("*"); return nil }
        if ctx.selection.hasSelection, chars == "a" { leader.arm("a"); return nil }
        if ctx.selection.hasSelection, chars == "l" { leader.arm("l"); return nil }

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
        case ("a", "c"): ItemClipboard.copy(selected)   // copy includes resolved
        case ("l", "t"): _ = ctx.actions.reclassify(selected, .todo)
        case ("l", "r"): _ = ctx.actions.reclassify(selected, .reminder)
        case ("l", "e"): _ = ctx.actions.reclassify(selected, .explore)
        case ("l", "l"): presentListEditor(for: selected, ctx)
        default: return false
        }
        return true
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
