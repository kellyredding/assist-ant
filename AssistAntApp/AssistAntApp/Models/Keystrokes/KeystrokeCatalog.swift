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
    static let listTabs: Set<MainTab> = [.schedule, .icebox, .trash]
    private static let nonTrashLists: Set<MainTab> = [.schedule, .icebox]
    private static let trashOnly: Set<MainTab> = [.trash]

    /// Built by appending rather than one `+` chain: eight concatenated array
    /// literals push the type-checker past its budget and fail to compile.
    static let all: [KeystrokeEntry] = {
        var out: [KeystrokeEntry] = []
        out += global
        out += windowAndViews
        out += lists
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
              section: .global, availability: .always),
        .init(binding: .capture(.todo), label: "Capture: To-do",
              section: .global, availability: .always),
        .init(binding: .capture(.reminder), label: "Capture: Reminder",
              section: .global, availability: .always),
        .init(binding: .capture(.explore), label: "Capture: Explore",
              section: .global, availability: .always),
        .init(binding: .capture(.task), label: "Capture: Task",
              section: .global, availability: .always),
        .init(binding: .statusPopover, label: "Status popover",
              section: .global, availability: .always),
    ]

    // MARK: - Window & views

    private static let windowAndViews: [KeystrokeEntry] = [
        .init(binding: .literal("⌘H"), label: "Previous view",
              section: .windowAndViews, availability: .viewSwitch),
        .init(binding: .literal("⌘←"), label: "Previous view",
              section: .windowAndViews, availability: .viewSwitch),
        .init(binding: .literal("⌘L"), label: "Next view",
              section: .windowAndViews, availability: .viewSwitch),
        .init(binding: .literal("⌘→"), label: "Next view",
              section: .windowAndViews, availability: .viewSwitch),
        .init(binding: .literal("⌘,"), label: "Settings",
              section: .windowAndViews, availability: .app),
        .init(binding: .literal("⌘W"), label: "Close window",
              section: .windowAndViews, availability: .app),
        .init(binding: .literal("⌥⌘H"), label: "Hide others",
              section: .windowAndViews, availability: .app),
        .init(binding: .literal("⌘Q"), label: "Quit Assist Ant",
              section: .windowAndViews, availability: .app),
        .init(binding: .literal("⌘/"), label: "Keyboard shortcuts",
              section: .windowAndViews, availability: .app),
    ]

    // MARK: - Lists

    /// Navigation and selection are live whenever a list surface is showing;
    /// the `a` and `l` leaders arm only once something is selected, which is
    /// why they carry a different availability. `*` needs no selection — it is
    /// how you make one.
    private static let lists: [KeystrokeEntry] = [
        .init(binding: .literal("j"), label: "Focus next item",
              section: .lists, availability: .tabs(listTabs)),
        .init(binding: .literal("k"), label: "Focus previous item",
              section: .lists, availability: .tabs(listTabs)),
        .init(binding: .literal("x"), label: "Toggle selection on focused item",
              section: .lists, availability: .tabs(listTabs)),
        .init(binding: .literal("⏎"), label: "Open focused item",
              section: .lists, availability: .tabs(listTabs)),
        .init(binding: .literal("* a"), label: "Select all in group",
              section: .lists, availability: .tabs(listTabs)),
        .init(binding: .literal("* n"), label: "Clear selection",
              section: .lists, availability: .tabs(listTabs)),

        .init(binding: .literal("a d"), label: "Done / Dismiss",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists)),
        .init(binding: .literal("a d"), label: "Delete permanently",
              section: .lists, availability: .tabsWithSelection(trashOnly)),
        .init(binding: .literal("a r"), label: "Restore / Reopen",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("a i"), label: "Move to Icebox",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("a v"), label: "Remove from Icebox",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("a c"), label: "Copy to clipboard",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("a l"), label: "Open link in browser",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("a p"), label: "Put back",
              section: .lists, availability: .tabsWithSelection(trashOnly)),

        .init(binding: .literal("l t"), label: "Change kind to To-do",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("l r"), label: "Change kind to Reminder",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("l e"), label: "Change kind to Explore",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("l l"), label: "Add or change list",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("l s"), label: "Reschedule…",
              section: .lists, availability: .tabsWithSelection(listTabs)),
        .init(binding: .literal("l d"), label: "Delete",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists)),
        .init(binding: .literal("l p"), label: "Put back",
              section: .lists,
              availability: .tabsWithSelection(nonTrashLists)),
    ]

    // MARK: - Reader

    /// The same `a` / `l` vocabulary as the lists, applied to the one open
    /// item instead of a selection.
    private static let reader: [KeystrokeEntry] = [
        .init(binding: .literal("j"), label: "Next item",
              section: .reader, availability: .reader),
        .init(binding: .literal("k"), label: "Previous item",
              section: .reader, availability: .reader),
        .init(binding: .literal("esc"), label: "Close reader",
              section: .reader, availability: .reader),
        .init(binding: .literal("a d"), label: "Done / Dismiss",
              section: .reader, availability: .reader),
        .init(binding: .literal("a r"), label: "Restore / Reopen",
              section: .reader, availability: .reader),
        .init(binding: .literal("a i"), label: "Move to Icebox",
              section: .reader, availability: .reader),
        .init(binding: .literal("a v"), label: "Remove from Icebox",
              section: .reader, availability: .reader),
        .init(binding: .literal("a c"), label: "Copy to clipboard",
              section: .reader, availability: .reader),
        .init(binding: .literal("a l"), label: "Open link in browser",
              section: .reader, availability: .reader),
        .init(binding: .literal("a p"), label: "Put back (from Trash)",
              section: .reader, availability: .reader),
        .init(binding: .literal("l t"), label: "Change kind to To-do",
              section: .reader, availability: .reader),
        .init(binding: .literal("l r"), label: "Change kind to Reminder",
              section: .reader, availability: .reader),
        .init(binding: .literal("l e"), label: "Change kind to Explore",
              section: .reader, availability: .reader),
        .init(binding: .literal("l l"), label: "Add or change list",
              section: .reader, availability: .reader),
        .init(binding: .literal("l s"), label: "Reschedule…",
              section: .reader, availability: .reader),
        .init(binding: .literal("l d"), label: "Delete",
              section: .reader, availability: .reader),
        .init(binding: .literal("l p"), label: "Put back",
              section: .reader, availability: .reader),
    ]

    // MARK: - Terminal & agent

    private static let terminal: [KeystrokeEntry] = [
        .init(binding: .literal("⌘T"), label: "Focus session pane",
              section: .terminal, availability: .app),
        .init(binding: .literal("⇧⌘T"), label: "Open shell pane",
              section: .terminal, availability: .app),
        .init(binding: .literal("⌘W"), label: "Close shell pane",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⌘S"), label: "Scrollback",
              section: .terminal, availability: .app),
        .init(binding: .literal("⌘0"), label: "Default terminal font size",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⌘="), label: "Bigger terminal font",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⌘-"), label: "Smaller terminal font",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⌃⌘K"), label: "Trim buffer",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⌃L"), label: "Reflow buffer",
              section: .terminal, availability: .terminalPane),
        .init(binding: .literal("⇧⌘⌫"), label: "Clear session",
              section: .terminal, availability: .app),
        .init(binding: .literal("⌃⌘⌫"), label: "Compact session",
              section: .terminal, availability: .app),
    ]

    // MARK: - Find

    private static let find: [KeystrokeEntry] = [
        .init(binding: .literal("⌘F"), label: "Find in scrollback",
              section: .find, availability: .app),
        .init(binding: .literal("⏎"), label: "Next match",
              section: .find, availability: .findBar),
        .init(binding: .literal("⇧⏎"), label: "Previous match",
              section: .find, availability: .findBar),
        .init(binding: .literal("esc"), label: "Dismiss find bar",
              section: .find, availability: .findBar),
    ]

    // MARK: - Text entry

    private static let textEntry: [KeystrokeEntry] = [
        .init(binding: .textEntryCommit, label: "Send / commit text",
              section: .textEntry, availability: .app),
        .init(binding: .textEntryNewline, label: "Insert a newline",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⌘Z"), label: "Undo",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⇧⌘Z"), label: "Redo",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⌘X"), label: "Cut",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⌘C"), label: "Copy",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⌘V"), label: "Paste",
              section: .textEntry, availability: .app),
        .init(binding: .literal("⌘A"), label: "Select all text",
              section: .textEntry, availability: .app),
    ]

    // MARK: - Popovers

    /// The capture and status popovers are separate windows with their own key
    /// handling. Documented here, but never *active* from this sheet's point
    /// of view — the sheet only opens from the main window — so these rows
    /// always render dimmed, which is the honest reading.
    private static let popovers: [KeystrokeEntry] = [
        .init(binding: .textEntryCommit, label: "Send the capture",
              section: .popovers, availability: .panel("Capture popover")),
        .init(binding: .textEntryNewline, label: "Insert a newline",
              section: .popovers, availability: .panel("Capture popover")),
        .init(binding: .literal("esc"), label: "Dismiss the capture",
              section: .popovers, availability: .panel("Capture popover")),
        .init(binding: .literal("⌘1…5"), label: "Switch capture kind",
              section: .popovers, availability: .panel("Capture popover")),
        // Wording tracks the hint the status popover prints on itself, so the
        // two cannot describe the same keys differently.
        .init(binding: .literal("↑ ↓"), label: "Move between controls",
              section: .popovers, availability: .panel("Status popover")),
        .init(binding: .literal("␣ ⏎"), label: "Choose the focused control",
              section: .popovers, availability: .panel("Status popover")),
        .init(binding: .literal("esc"), label: "Dismiss the status popover",
              section: .popovers, availability: .panel("Status popover")),
    ]
}
