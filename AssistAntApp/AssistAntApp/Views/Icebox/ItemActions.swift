import AppKit
import SwiftUI

/// The shared item-actions cluster: a Resolve slot and an Icebox slot. It drives
/// a SET of 1..N items, so one component serves the list-row hover, the reader
/// header, and the batch control bar; every label and enabled state reads the
/// aggregate (`ItemActionState`).
///
/// The two slots are "proper opposites" — no separate Undo:
///  - **Resolve**: active → Done/Dismiss (`complete`); resolved → Restore
///    (`reopen`). Always enabled.
///  - **Icebox**: label flips with iceboxed state — iceboxed → Remove from
///    Icebox (`removeFromIcebox`), else Move to Icebox (`moveToIcebox`). Both
///    preserve the item's scheduled day; the flag only supersedes display. It
///    is *disabled* (not relabeled) while resolved, so Restore re-enables it.
///
/// Batch actions hit the active members (a resolved item has no icebox action
/// and is already complete). `onChange` reports the single updated item to a
/// caller holding its own copy (the reader); a batch caller omits it.
struct ItemActions: View {
    let items: [Item]
    var onChange: (Item) -> Void = { _ in }
    let actions: ActionableActions
    /// The batch control bar passes true → labels and kind-menu items underline
    /// their chord letter. Default false (row hover, reader header) keeps plain
    /// labels, since the chords only fire on a batch selection.
    var showsMnemonics: Bool = false
    /// The Today sidebar passes true → the Resolve and Icebox slots render SF
    /// Symbols instead of text labels, to fit the narrow column. Default false
    /// keeps the text labels everywhere else. The ⋮ kind menu is already a glyph.
    var glyphs: Bool = false

    @State private var kindMenuHovering = false

    /// The mnemonic char for a label, or nil when mnemonics are off.
    private func mnem(_ c: Character) -> Character? { showsMnemonics ? c : nil }

    /// Kind-menu mnemonic: To-do → T, Reminder → R, Explore → E.
    private static func kindMnemonic(_ kind: ItemType) -> Character {
        switch kind {
        case .todo: return "T"
        case .reminder: return "R"
        case .explore: return "E"
        case .calendar: return " "
        }
    }

    private var state: ItemActionState { ItemActionState(items) }
    /// The members an action targets: resolved items are skipped (already
    /// complete; no icebox action). For a single active item this is `items`.
    private var activeItems: [Item] { items.filter { $0.resolvedAt == nil } }

    var body: some View {
        HStack(spacing: 6) {
            resolveButton
            iceboxButton
            CopyButton(text: ItemClipboard.serialize(items))
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
            CapsuleActionButton(title: "Restore", compact: true, mnemonic: mnem("R"),
                                systemImage: glyphs ? "arrow.uturn.backward" : nil) {
                apply(items) { actions.reopen($0) }
            }
        } else {
            CapsuleActionButton(title: state.resolveVerb, compact: true, mnemonic: mnem("D"),
                                systemImage: glyphs ? "checkmark" : nil) {
                apply(activeItems) { actions.complete($0) }
            }
        }
    }

    // Icebox: the label is purely the would-be move by iceboxed state, so the
    // text never changes on resolve/restore — only `disabled` flips.
    @ViewBuilder
    private var iceboxButton: some View {
        CapsuleActionButton(title: iceboxTitle, compact: true,
                            mnemonic: mnem(state.allIceboxed ? "v" : "i"),
                            systemImage: glyphs
                                ? (state.allIceboxed ? "snowflake.slash" : "snowflake")
                                : nil) {
            if state.allIceboxed {
                apply(activeItems) { actions.removeFromIcebox($0) }
            } else {
                apply(activeItems) { actions.moveToIcebox($0) }
            }
        }
        .disabled(state.allResolved)
        .opacity(state.allResolved ? 0.4 : 1)
    }

    private var iceboxTitle: String {
        state.allIceboxed ? "Remove from Icebox" : "Move to Icebox"
    }

    // A real pointer-button (hover highlight + hand cursor, like the close /
    // link buttons) — the overlay is the topmost hit view, so the hand cursor
    // wins over the glyph everywhere. A SwiftUI Menu can't be a pointerButton
    // (the button would eat the click the menu needs), so the click pops an
    // AppKit NSMenu built from the same items. Vertical triple-dots: the
    // horizontal `ellipsis` rotated 90° (no guaranteed vertical SF Symbol).
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

        let header = NSMenuItem(title: "Change kind", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for kind in [ItemType.todo, .reminder, .explore] {
            // Checkmark only when every item already is this kind.
            let allThisKind = items.allSatisfy { $0.typeData.kind == kind.rawValue }
            menu.addItem(ClosureMenuItem(
                title: ActionableKindLabel.menuTitle(kind),
                mnemonic: showsMnemonics ? Self.kindMnemonic(kind) : nil,
                state: allThisKind ? .on : .off
            ) { apply(items) { actions.reclassify($0, kind) } })
        }

        menu.addItem(.separator())
        // The editor prefills the shared list name (nil when the set spans
        // multiple lists) and applies the choice to every item. The menu's
        // tracking loop has ended by the time this fires, so spinning the
        // editor's modal run loop here is safe.
        menu.addItem(ClosureMenuItem(
            title: listMenuTitle,
            mnemonic: showsMnemonics ? "l" : nil
        ) {
            switch ListEditorWindowController.present(currentName: sharedListName) {
            case .cancel: break
            case .save(let name): apply(items) { actions.setListName($0, name) }
            case .remove: apply(items) { actions.setListName($0, nil) }
            }
        })

        // Match the window's light/dark appearance — a detached NSMenu otherwise
        // defaults to the system appearance — and clamp the origin so the whole
        // menu stays inside the window instead of spilling past its edge.
        // `in: nil` → `at` is the menu's top-left in screen coordinates (the
        // menu extends down and right from there).
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

/// An NSMenuItem that runs a closure when chosen (it is its own target/action),
/// so a SwiftUI-built popup menu needs no separate @objc coordinator.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, mnemonic: Character? = nil,
         state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        self.state = state
        if let mnemonic,
           let r = title.range(of: String(mnemonic), options: .caseInsensitive) {
            let attr = NSMutableAttributedString(string: title)
            attr.addAttribute(.underlineStyle,
                              value: NSUnderlineStyle.single.rawValue,
                              range: NSRange(r, in: title))
            attributedTitle = attr
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }
}
