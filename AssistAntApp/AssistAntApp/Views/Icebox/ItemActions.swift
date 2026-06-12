import SwiftUI

/// The shared item-actions cluster: a Resolve slot and an Icebox slot. It drives
/// a SET of 1..N items, so one component serves the list-row hover, the reader
/// header, and the batch control bar; every label and enabled state reads the
/// aggregate (`ItemActionState`).
///
/// The two slots are "proper opposites" — no separate Undo:
///  - **Resolve**: active → Done/Dismiss (`complete`); resolved → Restore
///    (`reopen`). Always enabled.
///  - **Icebox**: label is always the would-be move by iceboxed state —
///    iceboxed → Move to Today (`moveToToday`), else Move to Icebox
///    (`moveToIcebox`). It is *disabled* (not relabeled) while resolved, so
///    Restore just re-enables the very same button.
///
/// Batch actions hit the active members (a resolved item has no icebox action
/// and is already complete). `onChange` reports the single updated item to a
/// caller holding its own copy (the reader); a batch caller omits it.
struct ItemActions: View {
    let items: [Item]
    var onChange: (Item) -> Void = { _ in }

    @ObservedObject private var model = IceboxModel.shared

    private var state: ItemActionState { ItemActionState(items) }
    /// The members an action targets: resolved items are skipped (already
    /// complete; no icebox action). For a single active item this is `items`.
    private var activeItems: [Item] { items.filter { $0.resolvedAt == nil } }

    var body: some View {
        HStack(spacing: 6) {
            resolveButton
            iceboxButton
            kindMenu
                .disabled(state.allResolved)
                .opacity(state.allResolved ? 0.4 : 1)
        }
    }

    // Resolve: Restore once everything is resolved, else the accumulated verb
    // (Done / Dismiss / "Done / Dismiss") completing the active members.
    @ViewBuilder
    private var resolveButton: some View {
        if state.allResolved {
            CapsuleActionButton(title: "Restore", compact: true) {
                apply(items) { model.reopen($0) }
            }
        } else {
            CapsuleActionButton(title: state.resolveVerb, compact: true) {
                apply(activeItems) { model.complete($0) }
            }
        }
    }

    // Icebox: the label is purely the would-be move by iceboxed state, so the
    // text never changes on resolve/restore — only `disabled` flips.
    @ViewBuilder
    private var iceboxButton: some View {
        CapsuleActionButton(title: iceboxTitle, compact: true) {
            if state.allIceboxed {
                apply(activeItems) { model.moveToToday($0) }
            } else {
                apply(activeItems) { model.moveToIcebox($0) }
            }
        }
        .disabled(state.allResolved)
        .opacity(state.allResolved ? 0.4 : 1)
    }

    private var iceboxTitle: String {
        state.allIceboxed ? "Move to Today" : "Move to Icebox"
    }

    private var kindMenu: some View {
        Menu {
            Section("Change kind") {
                ForEach([ItemType.todo, .reminder, .explore], id: \.self) { kind in
                    Button {
                        apply(items) { model.reclassify($0, to: kind) }
                    } label: {
                        // Checkmark only when every item already is this kind.
                        if items.allSatisfy({ $0.typeData.kind == kind.rawValue }) {
                            Label(ActionableKindLabel.menuTitle(kind), systemImage: "checkmark")
                        } else {
                            Text(ActionableKindLabel.menuTitle(kind))
                        }
                    }
                }
            }
            Button(listMenuTitle) {
                // Menu actions fire after the menu's tracking loop ends, so it
                // is safe to spin the modal window's nested run loop here. The
                // editor prefills the shared list name (nil when the set spans
                // multiple lists) and applies the choice to every item.
                switch ListEditorWindowController.present(currentName: sharedListName) {
                case .cancel: break
                case .save(let name): apply(items) { model.setListName($0, to: name) }
                case .remove: apply(items) { model.setListName($0, to: nil) }
                }
            }
        } label: {
            // Vertical triple-dots: rotate the horizontal `ellipsis` 90° (no
            // standalone vertical SF Symbol is guaranteed across SDKs).
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 13)).foregroundStyle(.primary)
                .frame(width: 22, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
    }

    /// "Add to list" when no item has a list, else "Change list".
    private var listMenuTitle: String {
        items.allSatisfy { $0.actionableListName == nil } ? "Add to list" : "Change list"
    }

    /// The shared list name when every item agrees, else nil (mixed selection).
    private var sharedListName: String? {
        let names = Set(items.map { $0.actionableListName })
        return names.count == 1 ? names.first! : nil
    }

    /// Dispatch an op over `targets`; report the single updated item to a reader
    /// caller (a batch omits onChange).
    private func apply(_ targets: [Item], _ op: ([Item]) -> [Item]) {
        let updated = op(targets)
        if items.count == 1, let u = updated.first { onChange(u) }
    }
}
