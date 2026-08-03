import AppKit

/// Keyboard chords for the scratch feed.
///
/// A sibling of `ActionableListChords` rather than a mode on it: that controller
/// works over `ActionableGroup`s, which the scratch feed is deliberately without
/// — it is one flat chronological list. Navigation is shared verbatim
/// (`j`/`k`/`x`, `*a`/`*n`), because moving around a list is the same act
/// wherever you are.
///
/// The *actions* deliberately diverge. Every one is on the `a` leader — `a r`
/// resolve, `a o` reopen, `a c` copy, `a d` delete — with no `l` leader at all.
/// On the index surfaces `l` addresses the ⋮ menu's kind and list commands, and
/// scratch has no ⋮ menu: its toolbar is the whole action set. A leader whose
/// only member was delete would be a letter to remember for no distinction
/// worth making.
///
/// Gating mirrors `ActionableListChords` exactly — this tab selected, no reader
/// open, the key window ours, and no *editable* text view holding focus. That
/// last clause is why the composer must be blurred before the chords answer:
/// while it holds focus the keystrokes are text, not commands.
@MainActor
final class ScratchListChords {
    /// What the controller needs from the pane, read per event so it always sees
    /// the current snapshot rather than a copy taken at install time.
    struct Context {
        let selection: ActionableSelection
        /// Visible rows in display order — the query-filtered feed.
        let visibleIDs: () -> [String]
        let selectedItems: () -> [Item]
        let focusedItem: () -> Item?
        /// True while showing the completed feed, which flips `a d` from
        /// resolve to reopen — the same key means "the useful thing here".
        let showingCompleted: () -> Bool
        let resolve: ([Item]) -> Void
        let unresolve: ([Item]) -> Void
        let delete: ([Item]) -> Void
        let copy: ([Item]) -> Void
        /// Enter on the focused row: edit it in place, scratch's answer to the
        /// other lists opening a reader.
        let edit: (Item) -> Void
    }

    private var monitor: Any?
    private let leader = LeaderChord()

    func install(_ ctx: Context) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            // `handle` returns nil to CONSUME a key. Never fall back to `event`
            // on a nil return — that revives consumed keystrokes and they beep
            // or bleed into whatever is behind. Only a deallocated self passes
            // the event through.
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
        guard MainTabNavigator.shared.selectedTab == .scratch,
              ItemViewerModel.shared.openItem == nil,
              NSApp.keyWindow is AssistAntWindow,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
        else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased()

        // A leader is armed → the second key applies the chord, or cancels and
        // falls through to normal single-key handling.
        if let armed = leader.take() {
            if applyChord(leader: armed, key: chars, ctx) { return nil }
        }

        // Arm a leader. `*` is always available — it is how you make a
        // selection; `a` acts on one, so it needs one first.
        if event.characters == "*" { leader.arm("*"); return nil }
        if ctx.selection.hasSelection, chars == "a" {
            leader.arm("a"); return nil
        }

        switch chars {
        case "j": ctx.selection.moveFocus(by: 1, order: ctx.visibleIDs()); return nil
        case "k": ctx.selection.moveFocus(by: -1, order: ctx.visibleIDs()); return nil
        case "x": ctx.selection.toggleSelectedFocused(); return nil
        default: break
        }
        // Bare Return edits the focused row. Modified Return is deliberately not
        // ours: the submit keystroke is how you open the composer for a *new*
        // note, and matching Return regardless of modifiers swallowed it here so
        // ⌘Return edited a row instead.
        if event.keyCode == 36 || event.keyCode == 76,      // Return / Enter
           event.modifierFlags
               .isDisjoint(with: [.command, .option, .control, .shift]),
           let item = ctx.focusedItem() {
            ctx.edit(item); return nil
        }
        return event
    }

    /// Apply a leader+key chord. True when it matched (swallow the key), false
    /// for an unknown second key (cancel the sequence, fall through).
    private func applyChord(
        leader: Character, key: String?, _ ctx: Context
    ) -> Bool {
        let selected = ctx.selectedItems()
        switch (leader, key) {
        case ("*", "a"): ctx.selection.selectAll(in: ctx.visibleIDs())
        case ("*", "n"): ctx.selection.clearSelection()
        // On the completed feed the resolve key reopens instead. One letter, the
        // action that is actually available — mirroring how the row's own glyph
        // flips rather than going dead.
        case ("a", "r") where ctx.showingCompleted(): ctx.unresolve(selected)
        case ("a", "r"): ctx.resolve(selected)
        case ("a", "o"): ctx.unresolve(selected)
        case ("a", "c"): ctx.copy(selected)
        case ("a", "d"): ctx.delete(selected)
        default: return false
        }
        return true
    }
}
