import AppKit
import SwiftUI

/// The Trash view's action cluster — a deliberately scaled-back fork of
/// `ItemActions`. A trashed item's one primary verb is Put back; the only other
/// affordances that make sense on an archived item are Copy, the external link,
/// and a trimmed ⋮ menu for archive cleanup (Change kind / Change list). No
/// Resolve or Move-to-Icebox: you put an item back before acting on it.
///
/// Like `ItemActions` it drives a SET of 1..N items, so one component serves the
/// trash row hover, the reader header (for an open trashed item), and the batch
/// control bar. Put back is disabled (with a tooltip) for synced items — sync
/// owns their lifecycle — and skips synced members in a batch.
struct TrashActions: View {
    let items: [Item]
    var onChange: (Item) -> Void = { _ in }
    let actions: ActionableActions
    /// The batch control bar / reader pass true → the Put back label underlines
    /// its chord letter. Default false (row hover) keeps a plain label.
    var showsMnemonics: Bool = false

    @State private var kindMenuHovering = false

    /// The mnemonic char for a label, or nil when mnemonics are off.
    private func mnem(_ c: Character) -> Character? { showsMnemonics ? c : nil }

    private var state: ItemActionState { ItemActionState(items) }
    /// Put back / Delete target the local (non-synced) members; synced ones are
    /// skipped (sync owns their lifecycle).
    private var nonSynced: [Item] { items.filter { !$0.isSynced } }

    var body: some View {
        HStack(spacing: 6) {
            putBackButton
            CopyButton(text: ItemClipboard.serialize(items))
            linkButton
            kindMenu
        }
    }

    // The Trash view's primary verb, a flipping pill: a deleted row offers Put
    // back (`a p`, underline P); a row already put back (held in place until
    // refresh) flips to Delete (`a d`, underline D) so an accidental put-back can
    // be undone — mirroring the resolve pill's Done ⇄ Restore flip. Disabled +
    // tooltipped when every target is synced; the action skips synced members.
    private var putBackButton: some View {
        let allDeleted = state.allDeleted
        return CapsuleActionButton(
            title: allDeleted ? "Put back" : "Delete",
            compact: true,
            mnemonic: mnem(allDeleted ? "P" : "D"),
            help: state.allSynced
                ? (allDeleted ? "Synced from Linear — put it back in Linear."
                              : "Synced from Linear — delete it in Linear.")
                : nil
        ) {
            if allDeleted { apply(nonSynced) { actions.putBack($0) } }
            else { apply(nonSynced) { actions.delete($0) } }
        }
        .disabled(state.allSynced)
        .opacity(state.allSynced ? 0.4 : 1)
    }

    // External link: identical to ItemActions.linkButton — open every linked
    // item's URL; always shown, disabled + dimmed when the set has none.
    private var linkButton: some View {
        let urls = ItemLinks.urls(for: items)
        return PointerIconButton(systemName: "arrow.up.right") {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
        .disabled(urls.isEmpty)
        .opacity(urls.isEmpty ? 0.4 : 1)
    }

    // Trimmed ⋮: Change kind + Change list only (archive cleanup) — no
    // Delete/Put-back duplication, no Resolve/Icebox. Same glyph + NSMenu
    // mechanics as ItemActions.kindMenu.
    private var kindMenu: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 13)).foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(kindMenuHovering ? 0.12 : 0)))
            .animation(.easeInOut(duration: 0.15), value: kindMenuHovering)
            .pointerButton(onHoverChange: { kindMenuHovering = $0 }, action: presentKindMenu)
    }

    private func presentKindMenu() {
        let menu = NSMenu()
        ActionableKindMenu.populate(
            into: menu, items: items, showsMnemonics: showsMnemonics,
            reclassify: { its, kind in apply(its) { actions.reclassify($0, kind) } },
            setListName: { its, name in apply(its) { actions.setListName($0, name) } })

        // Match the window appearance and clamp the origin inside the window —
        // same handling as ItemActions.presentKindMenu.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        menu.appearance = window?.effectiveAppearance
        var origin = NSEvent.mouseLocation
        if let frame = window?.frame {
            let size = menu.size
            origin.x = max(frame.minX, min(origin.x, frame.maxX - size.width))
            origin.y = min(frame.maxY, max(origin.y, frame.minY + size.height))
        }
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    /// Dispatch an op over `targets`; report the single updated item to a reader
    /// caller (a batch omits onChange).
    private func apply(_ targets: [Item], _ op: ([Item]) -> [Item]) {
        let updated = op(targets)
        if items.count == 1, let u = updated.first { onChange(u) }
    }
}
