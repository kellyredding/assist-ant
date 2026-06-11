import SwiftUI

/// The shared Icebox item actions — Done/Dismiss, Move to Today, and the
/// vertical-ellipsis menu (change kind + add/change list) — used both as the
/// hover overlay on a list row and in the actionable reader's control bar. The
/// clicked button becomes Undo in place and siblings that no longer apply are
/// disabled, all read from `item`:
///  - active:   [Done|Dismiss]   [Move to Today]    [⋮]
///  - resolved: [Undo]           [Move to Today ✗]  [⋮ ✗]
///  - moved:    [Done|Dismiss]   [Undo]             [⋮]
/// `onChange` reports the post-action item so a caller holding its own copy
/// (the reader) can refresh; a list row needs no callback — it re-renders from
/// the model's regrouped snapshot. The list editor opens as a small modal
/// window (ListEditorWindowController) centered over the main window.
struct IceboxItemActions: View {
    let item: Item
    var onChange: (Item) -> Void = { _ in }

    @ObservedObject private var model = IceboxModel.shared

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isMoved: Bool { item.resolvedAt == nil && item.iceboxedAt == nil }

    var body: some View {
        HStack(spacing: 6) {
            resolveButton
            moveButton
            kindMenu
                .disabled(isResolved)   // Done already scheduled it today
                .opacity(isResolved ? 0.4 : 1)
        }
    }

    /// Resolve slot: Undo once resolved, else the kind's verb (Done/Dismiss).
    /// Stays enabled on a moved item — you can still complete it.
    @ViewBuilder
    private var resolveButton: some View {
        if isResolved {
            CapsuleActionButton(title: "Undo", compact: true) { report(model.reopen(item)) }
        } else {
            CapsuleActionButton(
                title: ActionableKindLabel.resolveVerb(for: item), compact: true
            ) {
                report(model.complete(item))
            }
        }
    }

    /// Move slot: Undo once moved, else "Move to Today" — disabled when the
    /// item is resolved, since Done already scheduled it for today.
    @ViewBuilder
    private var moveButton: some View {
        if isMoved {
            CapsuleActionButton(title: "Undo", compact: true) { report(model.reIcebox(item)) }
        } else {
            CapsuleActionButton(title: "Move to Today", compact: true) {
                report(model.moveToToday(item))
            }
            .disabled(isResolved)
            .opacity(isResolved ? 0.4 : 1)
        }
    }

    /// The vertical triple-dot menu: change kind, and add/change the list
    /// (which opens the pane's in-window list-editor overlay).
    private var kindMenu: some View {
        Menu {
            Section("Change kind") {
                ForEach([ItemType.todo, .reminder, .explore], id: \.self) { kind in
                    Button {
                        report(model.reclassify(item, to: kind))
                    } label: {
                        if item.typeData.kind == kind.rawValue {
                            Label(ActionableKindLabel.menuTitle(kind), systemImage: "checkmark")
                        } else {
                            Text(ActionableKindLabel.menuTitle(kind))
                        }
                    }
                }
            }
            Button(listMenuTitle) {
                // Menu actions fire after the menu's tracking loop ends, so it
                // is safe to spin the modal window's nested run loop here.
                switch ListEditorWindowController.present(for: item) {
                case .cancel: break
                case .save(let name): report(model.setListName(item, to: name))
                case .remove: report(model.setListName(item, to: nil))
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

    /// "Add to list" when the item has no list, "Change list" when it does.
    private var listMenuTitle: String {
        item.actionableListName == nil ? "Add to list" : "Change list"
    }

    private func report(_ updated: Item?) {
        if let updated { onChange(updated) }
    }
}
