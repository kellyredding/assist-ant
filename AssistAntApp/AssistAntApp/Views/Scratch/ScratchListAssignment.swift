import Foundation

/// Presenting the list editor over a set of notes, and the title that names the
/// gesture.
///
/// Shared by the ⋮ menu's list item and the `l l` chord so the seed rule — the
/// shared list name, or nil when the set spans lists — has one definition. Two
/// copies would be two answers to "what does the field open on" for one modal.
enum ScratchListAssignment {
    /// "Add to list" while none of `notes` has one, else "Change list" — and the
    /// title the editor window gives itself, since it flips on the same value.
    static func menuTitle(for notes: [Item]) -> String {
        notes.allSatisfy { $0.scratchListName == nil }
            ? "Add to list" : "Change list"
    }

    /// Open the editor seeded with the notes' shared list name (nil when the set
    /// spans lists), then hand the outcome to `apply`. Blocks until dismissed;
    /// Cancel writes nothing, Remove clears the list.
    @MainActor
    static func present(
        for notes: [Item], apply: ([Item], String?) -> Void
    ) {
        guard !notes.isEmpty else { return }
        let names = Set(notes.map(\.scratchListName))
        let shared = names.count == 1 ? names.first! : nil
        switch ListEditorWindowController.present(currentName: shared) {
        case .cancel: break
        case .save(let name): apply(notes, name)
        case .remove: apply(notes, nil)
        }
    }
}
