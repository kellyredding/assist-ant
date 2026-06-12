import SwiftUI

/// The shared item-actions cluster: a resolve slot, an icebox-aware move slot,
/// and the ⋮ menu (change kind / list). It drives a SET of 1..N items, so one
/// component serves the list-row hover, the reader header, and the batch
/// control bar; every label and enabled state reads the aggregate
/// (`ItemActionState`).
///
/// `context` tells the move slot how to read an un-iceboxed item — "moved" in
/// the Icebox, "at rest" in the Schedule:
///  - `.icebox`:   iceboxed → Move to Today; moved → Undo
///  - `.schedule`: not iceboxed → Move to Icebox; frozen → Undo
/// The resolve slot is context-independent: Undo once every target is resolved,
/// else the accumulated verb (Done / Dismiss / "Done / Dismiss").
///
/// `onChange` reports the single updated item to a caller holding its own copy
/// (the reader); a batch caller omits it — the model updates the snapshot
/// directly.
struct ItemActions: View {
    enum Context { case icebox, schedule }

    let items: [Item]
    var context: Context = .icebox
    var onChange: (Item) -> Void = { _ in }

    @ObservedObject private var model = IceboxModel.shared

    private var state: ItemActionState { ItemActionState(items) }

    var body: some View {
        HStack(spacing: 6) {
            resolveButton
            moveButton
            kindMenu
                .disabled(state.allResolved)
                .opacity(state.allResolved ? 0.4 : 1)
        }
    }

    // Resolve: Undo once every target is resolved, else the accumulated verb.
    @ViewBuilder
    private var resolveButton: some View {
        if state.allResolved {
            CapsuleActionButton(title: "Undo", compact: true) { apply { model.reopen($0) } }
        } else {
            CapsuleActionButton(title: state.resolveVerb, compact: true) {
                apply { model.complete($0) }
            }
        }
    }

    // Move: an icebox toggle labeled by context; "all in the moved/frozen
    // state" flips it to Undo.
    @ViewBuilder
    private var moveButton: some View {
        switch context {
        case .icebox:
            if state.allMoved {
                CapsuleActionButton(title: "Undo", compact: true) { apply { model.reIcebox($0) } }
            } else {
                CapsuleActionButton(title: "Move to Today", compact: true) {
                    apply { model.moveToToday($0) }
                }
                .disabled(state.allResolved)
                .opacity(state.allResolved ? 0.4 : 1)
            }
        case .schedule:
            if state.allIceboxed {
                // Phase 2 TODO: the schedule Undo should restore the prior
                // scheduled day, not land on Today. moveToToday is the current
                // approximation; revisit when the Schedule list ships.
                CapsuleActionButton(title: "Undo", compact: true) { apply { model.moveToToday($0) } }
            } else {
                CapsuleActionButton(title: "Move to Icebox", compact: true) {
                    apply { model.moveToIcebox($0) }
                }
                .disabled(state.allResolved)
                .opacity(state.allResolved ? 0.4 : 1)
            }
        }
    }

    private var kindMenu: some View {
        Menu {
            Section("Change kind") {
                ForEach([ItemType.todo, .reminder, .explore], id: \.self) { kind in
                    Button {
                        apply { model.reclassify($0, to: kind) }
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
                case .save(let name): apply { model.setListName($0, to: name) }
                case .remove: apply { model.setListName($0, to: nil) }
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

    /// Dispatch a set op; report the single updated item to a reader caller.
    private func apply(_ op: ([Item]) -> [Item]) {
        let updated = op(items)
        if items.count == 1, let u = updated.first { onChange(u) }
    }
}
