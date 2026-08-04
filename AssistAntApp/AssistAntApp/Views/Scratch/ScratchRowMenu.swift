import AppKit
import SwiftUI

/// The scratch feed's ⋮ menu: convert this note — or the whole selection — into
/// an actionable item, or put it on a list.
///
/// The convert trio, a separator, then the list item. Scratch's other verbs are
/// already glyphs in the toolbar beside this one; what lands here is what a glyph
/// cannot carry — a target kind, or a name to type. The separator is the only
/// grouping the two need: three items sharing one verb, then the one item with a
/// different verb. There is still no "Change kind" header and no checkmarks,
/// unlike `ActionableKindMenu` — a scratch note is never already a to-do, so a
/// checkmark could only ever be off.
///
/// Drives a SET of 1..N notes, so one component serves both surfaces exactly as
/// `ItemActions` serves the row hover and the batch bar — the row passes
/// `[entry]`, the batch bar passes the selection.
struct ScratchRowMenu: View {
    let notes: [Item]
    /// The batch bar passes true → each item underlines its chord letter, since
    /// `l t` / `l r` / `l e` and `l l` only fire on a selection. Row hover keeps
    /// plain labels. Same convention as `ItemActions.showsMnemonics`.
    var showsMnemonics: Bool = false
    let convert: ([Item], ItemType) -> Void
    /// Set or clear the notes' list; nil clears it.
    let setListName: ([Item], String?) -> Void

    var body: some View {
        ItemMenuButton { menu in
            // `actionableCases` rather than a literal [.todo, .reminder,
            // .explore]: it is already the single source for "the kinds that
            // behave as work", and a fourth kind must not need a fourth edit
            // here to be offered.
            for kind in ItemType.actionableCases {
                let label = ActionableKindLabel.menuTitle(kind)
                menu.addItem(ClosureMenuItem(
                    title: "Convert to \(label)",
                    mnemonic: showsMnemonics ? ItemActions.kindMnemonic(kind) : nil,
                    // Scoped to the kind word: "Convert to To-do" repeats the T
                    // in "Convert", and an unscoped search underlines that one
                    // instead of the letter `l t` actually presses.
                    mnemonicScope: label
                ) { convert(notes, kind) })
            }
            // Separated from the convert trio because it is a different verb, and
            // titled by whether the targets already have a list — the same flip
            // the index surfaces' kind menu uses. No mnemonicScope: the first `l`
            // in both titles is the letter the chord presses.
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(
                title: ScratchListAssignment.menuTitle(for: notes),
                mnemonic: showsMnemonics ? "l" : nil
            ) {
                // The menu's tracking loop has ended by the time this fires, so
                // spinning the editor's modal run loop here is safe.
                ScratchListAssignment.present(for: notes, apply: setListName)
            })
        }
    }
}
