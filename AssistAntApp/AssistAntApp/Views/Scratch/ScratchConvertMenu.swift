import AppKit
import SwiftUI

/// The scratch feed's ⋮ menu: convert this note — or the whole selection — into
/// an actionable item.
///
/// Three flat items and nothing else. Scratch's other verbs are already glyphs
/// in the toolbar beside this one; the menu exists to hold the single action
/// that cannot be a glyph, because it needs a target kind. There is no "Change
/// kind" header and no checkmarks, unlike `ActionableKindMenu`: a scratch note
/// is never already a to-do, so a checkmark could only ever be off, and a
/// header over three items that share one verb is chrome.
///
/// Drives a SET of 1..N notes, so one component serves both surfaces exactly as
/// `ItemActions` serves the row hover and the batch bar — the row passes
/// `[entry]`, the batch bar passes the selection.
struct ScratchConvertMenu: View {
    let notes: [Item]
    /// The batch bar passes true → each item underlines its chord letter, since
    /// `l t` / `l r` / `l e` only fire on a selection. Row hover keeps plain
    /// labels. Same convention as `ItemActions.showsMnemonics`.
    var showsMnemonics: Bool = false
    let convert: ([Item], ItemType) -> Void

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
        }
    }
}
