import AppKit

/// Keyboard chords for the scratch feed.
///
/// A sibling of `ActionableListChords` rather than a mode on it: that controller
/// works over `ActionableGroup`s, and the scratch feed groups a row type of its
/// own — a note carries the offsets its query matched at, which an
/// `ActionableGroup`'s `Item`s have no room for. Navigation is shared verbatim
/// (`j`/`k`/`x`, `*a`/`*n`), because moving around a grouped list is the same act
/// wherever you are: `j`/`k` step past a folded group, and `*a` takes the focused
/// row's group rather than the whole feed.
///
/// The *actions* mostly diverge. Resolve, reopen, copy, and delete are on the
/// `a` leader — `a r`, `a o`, `a c`, `a d` — one letter each for the glyphs in
/// the row and batch toolbars.
///
/// `l` addresses the ⋮ menu, on every surface that has one, and scratch now has
/// one: `l t` / `l r` / `l e` convert the selection into a to-do, a reminder, or
/// an explore. Those are the same three letters `ActionableListChords` binds to
/// `reclassify`, deliberately — "make this row that kind" is one gesture whether
/// the row is an actionable being re-kinded or a note being converted, and it
/// should not cost two chords to remember. `l l` opens the same list editor on
/// the same chord, because a note's list is the same thing a to-do's list is.
/// What is still absent is the scheduled day (`l s`) — a note is not work until
/// it is converted into some — and delete, which is already `a d`.
///
/// Both leaders arm only on an *unmodified* press: ⌘L is View ▸ Next view and
/// ⌘A is Select all, and a local monitor sees a key before the menu bar does —
/// so an ungated leader would eat both the moment anything was ticked. The
/// reader's monitor gates the same two leaders the same way.
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
        /// Visible rows in display order — the query-filtered feed, minus the
        /// notes any collapsed group holds.
        let visibleIDs: () -> [String]
        /// The ids of every note in the group holding focus — `* a`'s target. A
        /// closure rather than the groups themselves, so this controller never
        /// has to name the feed's group type.
        let idsInFocusedGroup: () -> [String]
        let selectedItems: () -> [Item]
        let focusedItem: () -> Item?
        /// True while showing the completed feed, which flips `a d` from
        /// resolve to reopen — the same key means "the useful thing here".
        let showingCompleted: () -> Bool
        let resolve: ([Item]) -> Void
        let unresolve: ([Item]) -> Void
        let delete: ([Item]) -> Void
        let copy: ([Item]) -> Void
        /// Convert the selection into an actionable item of `kind` — the ⋮
        /// menu's one command, reached from the keyboard by `l t`/`l r`/`l e`.
        /// Fire and forget: it returns nothing because nothing lands here.
        let convert: ([Item], ItemType) -> Void
        /// Set or clear the list on the selection — the ⋮ menu's assign command,
        /// reached from the keyboard by `l l`. Synchronous: the editor has closed
        /// and the write has landed by the time it returns.
        let setListName: ([Item], String?) -> Void
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
              // Same reasoning as ActionableListChords: the cheat sheet is an
              // overlay in this window, and the editable-text gate below catches
              // its search field only incidentally.
              !KeystrokeSheetModel.isClaimingKeyboard,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
        else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased()
        // Plain keys only, for the leaders and for j/k/x. A local monitor is
        // handed the event before the main menu's key equivalents, so without
        // this the `l` leader swallows ⌘L (View ▸ Next view), `a` swallows ⌘A,
        // and `x` swallows ⌘X — each of them the instant something is ticked.
        // Shift is not excluded: `*` is ⇧8.
        let plain = event.modifierFlags
            .isDisjoint(with: [.command, .option, .control])

        // A leader is armed → the second key applies the chord, or cancels and
        // falls through to normal single-key handling. The second key must be
        // plain too: with `a` armed, ⌘D would otherwise delete the selection
        // instead of reaching the menu bar.
        if let armed = leader.take() {
            if applyChord(leader: armed, key: plain ? chars : nil, ctx) {
                return nil
            }
        }

        // Arm a leader. `*` is always available — it is how you make a
        // selection; `a` and `l` act on one, so they need one first.
        if plain, event.characters == "*" { leader.arm("*"); return nil }
        if plain, ctx.selection.hasSelection, chars == "a" {
            leader.arm("a"); return nil
        }
        if plain, ctx.selection.hasSelection, chars == "l" {
            leader.arm("l"); return nil
        }

        if plain {
            switch chars {
            case "j": ctx.selection.moveFocus(by: 1, order: ctx.visibleIDs()); return nil
            case "k": ctx.selection.moveFocus(by: -1, order: ctx.visibleIDs()); return nil
            case "x":
                ctx.selection.toggleSelectedFocused(in: ctx.visibleIDs())
                return nil
            default: break
            }
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
        // The focused row's group, not the whole feed: the same scoping the index
        // surfaces apply, so `*a` means "this list" on every grouped surface.
        // Empty when focus sits nowhere visible, which selects nothing rather
        // than seeding a selection no row can show.
        case ("*", "a"): ctx.selection.selectAll(in: ctx.idsInFocusedGroup())
        case ("*", "n"): ctx.selection.clearSelection()
        // On the completed feed the resolve key reopens instead. One letter, the
        // action that is actually available — mirroring how the row's own glyph
        // flips rather than going dead.
        case ("a", "r") where ctx.showingCompleted(): ctx.unresolve(selected)
        case ("a", "r"): ctx.resolve(selected)
        case ("a", "o"): ctx.unresolve(selected)
        case ("a", "c"): ctx.copy(selected)
        case ("a", "d"): ctx.delete(selected)
        // The same letters ActionableListChords binds to reclassify, on purpose.
        // No completed-feed variant, unlike `a r`: converting a note you already
        // ticked is minting new work out of parked text, not editing a finished
        // item, so the chord means the same thing on both feeds.
        case ("l", "t"): ctx.convert(selected, .todo)
        case ("l", "r"): ctx.convert(selected, .reminder)
        case ("l", "e"): ctx.convert(selected, .explore)
        // The same chord the index surfaces use for the same editor, because a
        // note's list is the same thing a to-do's list is. The modal is safe from
        // inside this monitor: while it runs, the key window is not an
        // AssistAntWindow, so the gate above stands this controller down and the
        // editor's own field and Escape monitor get every key.
        case ("l", "l"):
            ScratchListAssignment.present(for: selected) { notes, name in
                ctx.setListName(notes, name)
            }
        default: return false
        }
        return true
    }
}
