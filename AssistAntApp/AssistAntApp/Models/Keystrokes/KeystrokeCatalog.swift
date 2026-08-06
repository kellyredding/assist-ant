import Foundation

/// Every keystroke Assist Ant answers to, hand-authored.
///
/// A second statement of facts that already live in `MainMenu`, the two chord
/// tables, the `KeystrokeShortcuts` names, and Galactic — so it can drift from
/// them. That is accepted knowingly: the ~38 chord bindings exist only inside
/// two switch statements and cannot be derived, and deriving only the menu
/// half would automate the entries macOS already displays while leaving the
/// valuable ones hand-written anyway. Driving the chord tables from this
/// catalog is the fix, and is deliberately a later step.
///
/// Anything the user can rebind is named symbolically (`.capture`,
/// `.textEntryCommit`) rather than spelled out, so the sheet reads the live
/// value and cannot contradict Settings.
enum KeystrokeCatalog {

    /// The surfaces that install `ActionableListChords`. Terminal and Tasks do
    /// not, so their chords genuinely do not exist there.
    ///
    /// Also the three surfaces the ⌘ sublist rungs walk — the same members for a
    /// different reason, since those are menu key equivalents rather than chords.
    /// One set rather than a second holding the same value: the value is what a
    /// row renders as ("in Schedule, Icebox, Trash"), and two sets spelling one
    /// place is how the sheet ends up naming two. Scratch stays out deliberately —
    /// it installs `ScratchListChords`, so widening this would hand it twenty
    /// `a`/`l` rows it does not implement.
    static let listTabs: Set<MainTab> = [.schedule, .icebox, .trash]
    private static let nonTrashLists: Set<MainTab> = [.schedule, .icebox]
    private static let trashOnly: Set<MainTab> = [.trash]
    /// Days exist on one surface, so the ⇧⌘ day rungs are scoped to it.
    private static let scheduleOnly: Set<MainTab> = [.schedule]

    /// Built by appending rather than one `+` chain: eight concatenated array
    /// literals push the type-checker past its budget and fail to compile.
    static let all: [KeystrokeEntry] = {
        var out: [KeystrokeEntry] = []
        out += global
        out += windowAndViews
        out += lists
        out += scratch
        out += reader
        out += terminal
        out += find
        out += textEntry
        out += popovers
        return out
    }()

    // MARK: - Global

    /// Global hotkeys, live even when another app is frontmost. Every one is
    /// rebindable in Settings, so all are resolved rather than spelled out.
    private static let global: [KeystrokeEntry] = [
        .init(binding: .capture(.ask), label: "Capture: Ask",
              section: .global, availability: .always,
              aliases: "new question, ask claude, quick capture, create, prompt"),
        .init(binding: .capture(.todo), label: "Capture: To-do",
              section: .global, availability: .always,
              aliases: "new todo, add task, quick capture, create"),
        .init(binding: .capture(.reminder), label: "Capture: Reminder",
              section: .global, availability: .always,
              aliases: "new reminder, add reminder, quick capture, create"),
        .init(binding: .capture(.explore), label: "Capture: Explore",
              section: .global, availability: .always,
              aliases: "new explore, research, quick capture, create"),
        .init(binding: .capture(.task), label: "Capture: Task",
              section: .global, availability: .always,
              aliases: "new task, heartbeat, scheduled job, quick capture, create"),
        .init(binding: .statusPopover, label: "Status popover",
              section: .global, availability: .always,
              aliases: "menu bar, status bar, widget, tray"),
    ]

    // MARK: - Window & views

    /// A view is a tab everywhere except in this app's own vocabulary, so every
    /// row that switches one carries the other word.
    private static let windowAndViews: [KeystrokeEntry] = [
        .init(binding: .literal("⇧⌘H"), label: "Previous view",
              section: .windowAndViews, availability: .viewSwitch,
              aliases: "previous tab, switch tab, change view, back, go left"),
        .init(binding: .literal("⇧⌘←"), label: "Previous view",
              section: .windowAndViews, availability: .viewSwitch,
              aliases: "previous tab, switch tab, change view, back, go left"),
        .init(binding: .literal("⇧⌘L"), label: "Next view",
              section: .windowAndViews, availability: .viewSwitch,
              aliases: "next tab, switch tab, change view, forward, go right"),
        .init(binding: .literal("⇧⌘→"), label: "Next view",
              section: .windowAndViews, availability: .viewSwitch,
              aliases: "next tab, switch tab, change view, forward, go right"),
        .init(binding: .literal("⌘,"), label: "Settings",
              section: .windowAndViews, availability: .app,
              aliases: "preferences, prefs, config, options"),
        .init(binding: .literal("⌘W"), label: "Close window",
              section: .windowAndViews, availability: .app,
              aliases: "dismiss window, hide window"),
        .init(binding: .literal("⌥⌘H"), label: "Hide others",
              section: .windowAndViews, availability: .app,
              aliases: "focus, minimize others, hide other apps"),
        .init(binding: .literal("⌘Q"), label: "Quit Assist Ant",
              section: .windowAndViews, availability: .app,
              aliases: "exit, close app, shut down"),
        .init(binding: .literal("⌘/"), label: "Keyboard shortcuts",
              section: .windowAndViews, availability: .app,
              aliases: "cheat sheet, help, hotkeys, bindings, this sheet"),
    ]

    // MARK: - Lists

    /// Navigation and selection are live whenever a list surface is showing;
    /// the `a` and `l` leaders arm only once something is selected, which is
    /// why they carry a different availability. `*` needs no selection — it is
    /// how you make one.
    ///
    /// Both halves of a move carry the place they move to or from, so asking the
    /// sheet about the Trash or the Icebox answers with the whole round trip
    /// rather than the one row whose label happens to name it.
    private static let lists: [KeystrokeEntry] = [
        .init(binding: .literal("j"), label: "Focus next item",
              section: .lists, availability: .tabs(listTabs),
              aliases: "down, move down, next row, navigate"),
        .init(binding: .literal("k"), label: "Focus previous item",
              section: .lists, availability: .tabs(listTabs),
              aliases: "up, move up, previous row, navigate"),
        // The ladder: a bare letter steps a row, ⌘ steps a sublist, ⇧⌘ steps a
        // day. Authored next to j/k rather than after `* n` so the three rungs
        // read in order and the modifier hierarchy is legible from the keys
        // column alone.
        //
        // Four rows per rung, not two. The arrow forms are hidden `isAlternate`
        // menu items — they appear in no menu a reader can open — so this sheet
        // is the only place they are written down at all, the same reason ⇧⌘H
        // and ⇧⌘← are two rows in Window & Views.
        .init(binding: .literal("⌘K"), label: "Focus previous sublist",
              section: .lists, availability: .tabs(listTabs),
              aliases: "jump to the previous sublist, skip to the previous "
                  + "group, move up to the list above, move to the earlier "
                  + "section, focus the first row of the group above"),
        .init(binding: .literal("⌘↑"), label: "Focus previous sublist",
              section: .lists, availability: .tabs(listTabs),
              aliases: "jump to the previous sublist, skip to the previous "
                  + "group, move up to the list above, move to the earlier "
                  + "section, focus the first row of the group above"),
        .init(binding: .literal("⌘J"), label: "Focus next sublist",
              section: .lists, availability: .tabs(listTabs),
              aliases: "jump to the next sublist, skip to the next group, "
                  + "move down to the list below, move to the following "
                  + "section, focus the first row of the group below"),
        .init(binding: .literal("⌘↓"), label: "Focus next sublist",
              section: .lists, availability: .tabs(listTabs),
              aliases: "jump to the next sublist, skip to the next group, "
                  + "move down to the list below, move to the following "
                  + "section, focus the first row of the group below"),
        // Schedule alone, because Schedule is the only surface with days. The
        // `.tabs` case is load-bearing rather than incidental: ⇧⌘↑/⇧⌘↓ are
        // AppKit's extend-selection-to-document chords, so the rung has to stand
        // down to a focused editor — which is what `.tabs` says.
        .init(binding: .literal("⇧⌘K"), label: "Focus previous day",
              section: .lists, availability: .tabs(scheduleOnly),
              aliases: "jump to the previous day, skip back to the previous "
                  + "day, yesterday, the day before, change the day shown, "
                  + "scroll up to the earlier date"),
        .init(binding: .literal("⇧⌘↑"), label: "Focus previous day",
              section: .lists, availability: .tabs(scheduleOnly),
              aliases: "jump to the previous day, skip back to the previous "
                  + "day, yesterday, the day before, change the day shown, "
                  + "scroll up to the earlier date"),
        .init(binding: .literal("⇧⌘J"), label: "Focus next day",
              section: .lists, availability: .tabs(scheduleOnly),
              aliases: "jump to the next day, skip forward to the next day, "
                  + "tomorrow, the day after, change the day shown, "
                  + "scroll down to the following date"),
        .init(binding: .literal("⇧⌘↓"), label: "Focus next day",
              section: .lists, availability: .tabs(scheduleOnly),
              aliases: "jump to the next day, skip forward to the next day, "
                  + "tomorrow, the day after, change the day shown, "
                  + "scroll down to the following date"),
        .init(binding: .literal("x"), label: "Toggle selection on focused item",
              section: .lists, availability: .tabs(listTabs),
              aliases: "tick, check, mark, select, unselect"),
        .init(binding: .literal("⏎"), label: "Open focused item",
              section: .lists, availability: .tabs(listTabs),
              aliases: "detail, reader, preview, expand, view item"),
        .init(binding: .literal("* a"), label: "Select all in group",
              section: .lists, availability: .tabs(listTabs),
              aliases: "mark all, select every, all in list"),
        .init(binding: .literal("* n"), label: "Clear selection",
              section: .lists, availability: .tabs(listTabs),
              aliases: "deselect, unselect, select none"),

        .init(binding: .literal("a d"), label: "Done / Dismiss",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists),
              aliases: "complete, finish, tick, check off, resolve, close"),
        .init(binding: .literal("a d"), label: "Delete permanently",
              section: .lists, availability: .tabsWithSelection(trashOnly),
              aliases: "trash, purge, erase, empty trash, forever, destroy"),
        .init(binding: .literal("a r"), label: "Restore / Reopen",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "undo, uncomplete, unresolve, reactivate, undone"),
        .init(binding: .literal("a i"), label: "Move to Icebox",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "later, defer, snooze, backlog, hide, park"),
        .init(binding: .literal("a v"), label: "Remove from Icebox",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "un-icebox, activate, unhide, resume, unpark"),
        .init(binding: .literal("a c"), label: "Copy to clipboard",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "yank, pasteboard"),
        .init(binding: .literal("a l"), label: "Open link in browser",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "url, web, safari, external, visit"),
        .init(binding: .literal("a p"), label: "Put back",
              section: .lists, availability: .tabsWithSelection(trashOnly),
              aliases: "trash, restore, undelete, untrash, recover"),

        .init(binding: .literal("l t"), label: "Change kind to To-do",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "reclassify, change type, retype, todo"),
        .init(binding: .literal("l r"), label: "Change kind to Reminder",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "reclassify, change type, retype"),
        .init(binding: .literal("l e"), label: "Change kind to Explore",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "reclassify, change type, retype"),
        .init(binding: .literal("l l"), label: "Add or change list",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "group, file, categorize, tag, move to list"),
        .init(binding: .literal("l s"), label: "Reschedule…",
              section: .lists, availability: .tabsWithSelection(listTabs),
              aliases: "move date, change day, defer, due date, when, calendar"),
        .init(binding: .literal("l d"), label: "Delete",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists),
              aliases: "move to trash, bin, remove, discard, throw away"),
        .init(binding: .literal("l p"), label: "Put back",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists),
              aliases: "trash, restore, undelete, untrash, recover"),
    ]

    // MARK: - Scratch

    /// Scratch shares the lists' navigation verbatim — moving around a list is
    /// the same act wherever you are — and diverges only partly on the actions.
    ///
    /// The `a` leader covers the toolbar glyphs. The `l` leader addresses the ⋮
    /// menu, as it does on every surface that has one, and scratch's ⋮ holds the
    /// convert commands plus the list assignment — so `l t` / `l r` / `l e` are
    /// here, bound to the same letters the lists use for reclassify, and `l l`
    /// opens the same list editor those surfaces open. What is still absent is
    /// the scheduled day (`l s`): a note is not work until it is converted into
    /// some.
    ///
    /// The chords need the feed to own the keyboard, which the composer holds on
    /// arrival — Escape is what hands it over, so it leads the section.
    private static let scratch: [KeystrokeEntry] = [
        .init(binding: .literal("esc"),
              label: "Leave input mode (discards the draft)",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "cancel, discard draft, stop composing, blur, abandon"),
        .init(binding: .textEntryCommit, label: "Enter input mode",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "compose, write, new note, draft, add note, jot"),
        .init(binding: .literal("⌘F"), label: "Search notes",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "filter, find, query"),
        .init(binding: .literal("j"), label: "Focus next note",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "down, move down, next row, navigate"),
        .init(binding: .literal("k"), label: "Focus previous note",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "up, move up, previous row, navigate"),
        // The Lists section's two ⌘ rungs, worded identically. The chord walks the
        // same object on both surfaces — a named list of rows — whether the rows
        // are actionables or notes, exactly as `* a` below does, so it must not
        // read differently. Scratch says "note" where the *rows* are the subject;
        // a sublist is not a note, and that is where the line holds.
        //
        // Its own rows rather than the Lists rows widened onto `.scratch`, because
        // `listTabs` names the surfaces installing `ActionableListChords`. No day
        // rung here — the feed has no days.
        .init(binding: .literal("⌘K"), label: "Focus previous sublist",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "jump to the previous sublist, skip to the previous "
                  + "group, move up to the list above, move to the earlier "
                  + "section, focus the first row of the group above"),
        .init(binding: .literal("⌘↑"), label: "Focus previous sublist",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "jump to the previous sublist, skip to the previous "
                  + "group, move up to the list above, move to the earlier "
                  + "section, focus the first row of the group above"),
        .init(binding: .literal("⌘J"), label: "Focus next sublist",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "jump to the next sublist, skip to the next group, "
                  + "move down to the list below, move to the following "
                  + "section, focus the first row of the group below"),
        .init(binding: .literal("⌘↓"), label: "Focus next sublist",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "jump to the next sublist, skip to the next group, "
                  + "move down to the list below, move to the following "
                  + "section, focus the first row of the group below"),
        .init(binding: .literal("x"), label: "Toggle selection on focused note",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "tick, check, mark, select, unselect"),
        .init(binding: .literal("⏎"), label: "Edit focused note in place",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "inline edit, modify, change text, rewrite"),
        // Same wording as the Lists section's entry: the chord scopes to the
        // focused row's group on both surfaces, so it must not read differently.
        .init(binding: .literal("* a"), label: "Select all in group",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "mark all, select every, all in list"),
        .init(binding: .literal("* n"), label: "Clear selection",
              section: .scratch, availability: .tabs(scratchOnly),
              aliases: "deselect, unselect, select none"),
        .init(binding: .literal("a r"), label: "Resolve (reopen when completed)",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "done, complete, tick, check off, finish, archive"),
        .init(binding: .literal("a o"), label: "Reopen",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "unresolve, uncomplete, undo, undone"),
        .init(binding: .literal("a c"), label: "Copy to clipboard",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "yank, pasteboard"),
        .init(binding: .literal("a d"), label: "Delete",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "move to trash, bin, remove, discard, throw away"),
        // "Convert to …", not the lists' "Change kind to …" — same keys,
        // honestly different verbs, and matching the ⋮ menu titles exactly.
        .init(binding: .literal("l t"), label: "Convert to To-do",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "promote, turn into, change kind, make todo, shape"),
        .init(binding: .literal("l r"), label: "Convert to Reminder",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "promote, turn into, change kind, shape"),
        .init(binding: .literal("l e"), label: "Convert to Explore",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "promote, turn into, change kind, shape"),
        // The Lists section's label verbatim: it is the same editor on the same
        // chord, so two sections must not name it two ways.
        .init(binding: .literal("l l"), label: "Add or change list",
              section: .scratch,
              availability: .tabsWithSelection(scratchOnly),
              aliases: "group, file, categorize, tag, move to list"),
    ]

    private static let scratchOnly: Set<MainTab> = [.scratch]

    // MARK: - Reader

    /// The same `a` / `l` vocabulary as the lists, applied to the one open
    /// item instead of a selection.
    private static let reader: [KeystrokeEntry] = [
        .init(binding: .literal("j"), label: "Next item",
              section: .reader, availability: .reader,
              aliases: "down, navigate, forward"),
        .init(binding: .literal("k"), label: "Previous item",
              section: .reader, availability: .reader,
              aliases: "up, navigate, back"),
        .init(binding: .literal("esc"), label: "Close reader",
              section: .reader, availability: .reader,
              aliases: "dismiss, back, exit detail, close detail, preview"),
        .init(binding: .literal("a d"), label: "Done / Dismiss",
              section: .reader, availability: .reader,
              aliases: "complete, finish, tick, check off, resolve, close"),
        .init(binding: .literal("a r"), label: "Restore / Reopen",
              section: .reader, availability: .reader,
              aliases: "undo, uncomplete, unresolve, reactivate, undone"),
        .init(binding: .literal("a i"), label: "Move to Icebox",
              section: .reader, availability: .reader,
              aliases: "later, defer, snooze, backlog, hide, park"),
        .init(binding: .literal("a v"), label: "Remove from Icebox",
              section: .reader, availability: .reader,
              aliases: "un-icebox, activate, unhide, resume, unpark"),
        .init(binding: .literal("a c"), label: "Copy to clipboard",
              section: .reader, availability: .reader,
              aliases: "yank, pasteboard"),
        .init(binding: .literal("a l"), label: "Open link in browser",
              section: .reader, availability: .reader,
              aliases: "url, web, safari, external, visit"),
        .init(binding: .literal("a p"), label: "Put back (from Trash)",
              section: .reader, availability: .reader,
              aliases: "restore, undelete, untrash, recover"),
        .init(binding: .literal("l t"), label: "Change kind to To-do",
              section: .reader, availability: .reader,
              aliases: "reclassify, change type, retype, todo"),
        .init(binding: .literal("l r"), label: "Change kind to Reminder",
              section: .reader, availability: .reader,
              aliases: "reclassify, change type, retype"),
        .init(binding: .literal("l e"), label: "Change kind to Explore",
              section: .reader, availability: .reader,
              aliases: "reclassify, change type, retype"),
        .init(binding: .literal("l l"), label: "Add or change list",
              section: .reader, availability: .reader,
              aliases: "group, file, categorize, tag, move to list"),
        .init(binding: .literal("l s"), label: "Reschedule…",
              section: .reader, availability: .reader,
              aliases: "move date, change day, defer, due date, when, calendar"),
        .init(binding: .literal("l d"), label: "Delete",
              section: .reader, availability: .reader,
              aliases: "move to trash, bin, remove, discard, throw away"),
        .init(binding: .literal("l p"), label: "Put back",
              section: .reader, availability: .reader,
              aliases: "trash, restore, undelete, untrash, recover"),
    ]

    // MARK: - Terminal & agent

    private static let terminal: [KeystrokeEntry] = [
        .init(binding: .literal("⌘K"), label: "Focus session pane",
              section: .terminal, availability: .terminalTab,
              aliases: "agent, claude, jump to agent, session, "
                  + "go up a pane"),
        // The hidden `isAlternate` twin, bound when the pane commands were named
        // directionally and never given a row — so the sheet has been denying a
        // key that works. Same label, same aliases, same availability: it is the
        // same command, and a second wording would read as a second one.
        //
        // `.terminalTab`, not `.tabs([.terminal])`, for the reason that case's own
        // doc gives: these resolve a pane from the focus memory, so neither a
        // caret in the find bar nor an open reader stops them.
        .init(binding: .literal("⌘↑"), label: "Focus session pane",
              section: .terminal, availability: .terminalTab,
              aliases: "agent, claude, jump to agent, session, "
                  + "go up a pane"),
        .init(binding: .literal("⌘J"), label: "Focus shell pane",
              section: .terminal, availability: .terminalTab,
              aliases: "go to the shell, command line, go down a pane, "
                  + "switch to bash"),
        .init(binding: .literal("⌘↓"), label: "Focus shell pane",
              section: .terminal, availability: .terminalTab,
              aliases: "go to the shell, command line, go down a pane, "
                  + "switch to bash"),
        .init(binding: .literal("⌘O"), label: "Open shell pane",
              section: .terminal, availability: .terminalTab,
              aliases: "new shell, split, bash, zsh, login shell"),
        .init(binding: .literal("⌘W"), label: "Close shell pane",
              section: .terminal, availability: .terminalPane,
              aliases: "dismiss shell, close split, quit shell"),
        .init(binding: .literal("⌘S"), label: "Scrollback",
              section: .terminal, availability: .app,
              aliases: "history, transcript, log, output, buffer"),
        // All three name the surface and the thing in full, so "terminal",
        // "font" and "size" each turn up the whole group rather than a third of
        // it — which is also why they do NOT match the menu titles, where the
        // three read "Default", "Bigger" and "Smaller" under a heading that
        // supplies the same words once.
        //
        // The menu can lean on that heading because a menu is never filtered.
        // These rows are: a search strips a row of its neighbours, and a
        // lone "Bigger" then says nothing at all about what it resizes.
        .init(binding: .literal("⌘0"), label: "Default terminal font size",
              section: .terminal, availability: .terminalTab,
              aliases: "zoom, text size, reset zoom, actual size"),
        .init(binding: .literal("⌘="), label: "Bigger terminal font size",
              section: .terminal, availability: .terminalTab,
              aliases: "zoom in, larger, increase, bigger text"),
        .init(binding: .literal("⌘-"), label: "Smaller terminal font size",
              section: .terminal, availability: .terminalTab,
              aliases: "zoom out, smaller, decrease, smaller text"),
        .init(binding: .literal("⌃⌘K"), label: "Trim buffer",
              section: .terminal, availability: .terminalTab,
              aliases: "clear scrollback, prune, truncate, tidy"),
        .init(binding: .literal("⌃L"), label: "Reflow buffer",
              section: .terminal, availability: .terminalTab,
              aliases: "redraw, refresh, rewrap, repaint"),
        .init(binding: .literal("⇧⌘⌫"), label: "Clear session",
              section: .terminal, availability: .app,
              aliases: "wipe, reset, blank, clear screen"),
        .init(binding: .literal("⌃⌘⌫"), label: "Compact session",
              section: .terminal, availability: .app,
              aliases: "summarize, condense, context, shrink"),
    ]

    // MARK: - Find

    private static let find: [KeystrokeEntry] = [
        .init(binding: .literal("⌘F"), label: "Find in scrollback",
              section: .find, availability: .app,
              aliases: "search, query, filter, history, transcript"),
        .init(binding: .literal("⏎"), label: "Next match",
              section: .find, availability: .findBar,
              aliases: "find next, forward, down"),
        .init(binding: .literal("⇧⏎"), label: "Previous match",
              section: .find, availability: .findBar,
              aliases: "find previous, back, up"),
        .init(binding: .literal("esc"), label: "Dismiss find bar",
              section: .find, availability: .findBar,
              aliases: "close find, cancel search, exit find"),
    ]

    // MARK: - Text entry

    private static let textEntry: [KeystrokeEntry] = [
        .init(binding: .textEntryCommit, label: "Send / commit text",
              section: .textEntry, availability: .app,
              aliases: "submit, post, confirm, save"),
        .init(binding: .textEntryNewline, label: "Insert a newline",
              section: .textEntry, availability: .app,
              aliases: "line break, multiline, soft return, new line"),
        .init(binding: .literal("⌘Z"), label: "Undo",
              section: .textEntry, availability: .app,
              aliases: "revert, take back"),
        .init(binding: .literal("⇧⌘Z"), label: "Redo",
              section: .textEntry, availability: .app,
              aliases: "undo the undo, forward"),
        .init(binding: .literal("⌘X"), label: "Cut",
              section: .textEntry, availability: .app,
              aliases: "clipboard, move text"),
        .init(binding: .literal("⌘C"), label: "Copy",
              section: .textEntry, availability: .app,
              aliases: "clipboard, yank, pasteboard"),
        .init(binding: .literal("⌘V"), label: "Paste",
              section: .textEntry, availability: .app,
              aliases: "clipboard, insert"),
        .init(binding: .literal("⌘A"), label: "Select all text",
              section: .textEntry, availability: .app,
              aliases: "highlight all, mark all"),
    ]

    // MARK: - Popovers

    /// The capture and status popovers are separate windows with their own key
    /// handling. Documented here, but never *active* from this sheet's point
    /// of view — the sheet only opens from the main window — so these rows
    /// always render dimmed, which is the honest reading.
    private static let popovers: [KeystrokeEntry] = [
        .init(binding: .textEntryCommit, label: "Send the capture",
              section: .popovers, availability: .panel("Capture popover"),
              aliases: "submit, post, save, confirm"),
        .init(binding: .textEntryNewline, label: "Insert a newline",
              section: .popovers, availability: .panel("Capture popover"),
              aliases: "line break, multiline, soft return, new line"),
        .init(binding: .literal("esc"), label: "Dismiss the capture",
              section: .popovers, availability: .panel("Capture popover"),
              aliases: "cancel, close capture, abort, discard"),
        .init(binding: .literal("⌘1…5"), label: "Switch capture kind",
              section: .popovers, availability: .panel("Capture popover"),
              aliases: "change type, ask, todo, reminder, explore, task"),
        // Wording tracks the hint the status popover prints on itself, so the
        // two cannot describe the same keys differently.
        .init(binding: .literal("↑ ↓"), label: "Move between controls",
              section: .popovers, availability: .panel("Status popover"),
              aliases: "navigate, arrows, focus"),
        .init(binding: .literal("␣ ⏎"), label: "Choose the focused control",
              section: .popovers, availability: .panel("Status popover"),
              aliases: "activate, press, select, toggle"),
        .init(binding: .literal("esc"), label: "Dismiss the status popover",
              section: .popovers, availability: .panel("Status popover"),
              aliases: "cancel, close status, menu bar"),
    ]
}
