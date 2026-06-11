import SwiftUI

/// One icebox item. Tapping the row body opens the reader. On hover, three
/// action buttons float right-aligned over a scrim; the slots stay fixed so
/// the layout doesn't shift, and the clicked button becomes Undo in place
/// while siblings that no longer apply are disabled (not removed):
///  - active:   [Done|Dismiss]   [Move to Today]    [⋮]
///  - resolved: [Undo]           [Move to Today ✗]  [⋮ ✗]   (struck/dimmed)
///  - moved:    [Done|Dismiss]   [Undo]             [⋮]     ("Moved to Today")
/// Done implicitly schedules today, so it disables Move + the kind menu;
/// a moved item can still be completed or reclassified. State is read from
/// the (locally-mutated) snapshot item, so an action's effect shows
/// immediately while the list keeps the row until refresh.
struct IceboxRow: View {
    let item: Item
    let onOpen: () -> Void

    @ObservedObject private var model = IceboxModel.shared
    @State private var isHovering = false

    private var isResolved: Bool { item.resolvedAt != nil }
    private var isMoved: Bool { item.resolvedAt == nil && item.iceboxedAt == nil }

    var body: some View {
        rowContent
            // Overlay (not a ZStack child) so the floating buttons never add
            // to the row's height — a hovered row stays the same size.
            .overlay(alignment: .trailing) {
                if isHovering { actions.padding(.trailing, 8) }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .padding(.horizontal, 8)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if let badge = ActionableKindLabel.badge(for: item) {
                Text(badge)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Text(item.title)
                .font(.callout).lineLimit(1)
                .strikethrough(isResolved)
            Spacer(minLength: 12)
            Text(statusText)
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .opacity(isResolved || isMoved ? 0.5 : 1)
        .padding(.vertical, 6).padding(.horizontal, 6)
        .contentShape(Rectangle())
        // Row body opens the reader; the action overlay sits above it.
        .pointerButton(onHoverChange: { _ in }, action: onOpen)
    }

    /// Right column under the title: the friendly iceboxed date, or the
    /// moved tag.
    private var statusText: String {
        if isMoved { return "Moved to Today" }
        guard let at = item.iceboxedAt else { return "" }
        return Self.dateFormatter.string(from: at)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            resolveButton
            moveButton
            kindMenu
                .disabled(isResolved)   // Done already scheduled it today
                .opacity(isResolved ? 0.4 : 1)
        }
        // Scrim so the floating buttons stay legible over the title/date.
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
        )
    }

    /// Resolve slot: Undo once resolved, else the kind's verb (Done/Dismiss).
    /// Stays enabled on a moved item — you can still complete it.
    @ViewBuilder
    private var resolveButton: some View {
        if isResolved {
            CapsuleActionButton(title: "Undo", compact: true) { model.reopen(item) }
        } else {
            CapsuleActionButton(
                title: ActionableKindLabel.resolveVerb(for: item), compact: true
            ) {
                model.complete(item)
            }
        }
    }

    /// Move slot: Undo once moved, else "Move to Today" — disabled when the
    /// item is resolved, since Done already scheduled it for today.
    @ViewBuilder
    private var moveButton: some View {
        if isMoved {
            CapsuleActionButton(title: "Undo", compact: true) { model.reIcebox(item) }
        } else {
            CapsuleActionButton(title: "Move to Today", compact: true) {
                model.moveToToday(item)
            }
            .disabled(isResolved)
            .opacity(isResolved ? 0.4 : 1)
        }
    }

    /// The vertical triple-dot menu to change kind. (Pointer-cursor on a
    /// SwiftUI Menu label is fiddly; if the hand cursor doesn't land, wrap the
    /// label so the pointerButton overlay stays topmost — see PointerButton.)
    private var kindMenu: some View {
        Menu {
            ForEach([ItemType.todo, .reminder, .explore], id: \.self) { kind in
                Button {
                    model.reclassify(item, to: kind)
                } label: {
                    if item.typeData.kind == kind.rawValue {
                        Label(ActionableKindLabel.menuTitle(kind), systemImage: "checkmark")
                    } else {
                        Text(ActionableKindLabel.menuTitle(kind))
                    }
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

    /// Friendly iceboxed date, e.g. "Jun 9".
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
