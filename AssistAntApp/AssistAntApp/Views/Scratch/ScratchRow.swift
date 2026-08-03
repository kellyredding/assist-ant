import AppKit
import SwiftUI

/// One entry in the scratch feed: a selection checkbox, the timestamp with the
/// hover toolbar beside it, and the body beneath.
///
/// The body renders as plain text, not Markdown. Scratch holds verbatim parked
/// values — ids, URLs, code fragments — and Markdown would silently eat the
/// `*`, `_`, and `#` in them. Rendering raw is both truer to what was pasted
/// and what makes a later search highlight tractable.
///
/// No detail view: double-clicking anywhere on the row edits in place.
struct ScratchRow: View {
    let entry: Item
    @ObservedObject var model: ScratchModel
    /// Observed separately from `model`, and that is the point: the selection is
    /// its own `ObservableObject` that the model merely holds, so observing the
    /// model does not subscribe to it. Without this the checkbox and the row
    /// tint only refreshed when some *other* state change forced a re-render —
    /// moving the pointer off the row — while the pane's count, which does
    /// observe it, updated immediately.
    @ObservedObject var selection: ActionableSelection

    init(entry: Item, model: ScratchModel) {
        self.entry = entry
        self.model = model
        self._selection = ObservedObject(wrappedValue: model.selection)
    }

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editorFocused: Bool

    private var isResolved: Bool { entry.resolvedAt != nil }
    private var isSelected: Bool {
        selection.selectedIDs.contains(entry.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerLine
            Group {
                if isEditing {
                    editor
                } else {
                    bodyText
                }
            }
            // Indented to start under the timestamp rather than under the
            // checkbox, so the checkbox reads as its own gutter column.
            .padding(.leading, Self.gutterWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ScratchMetrics.inset).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        // Without this the row is only hit-testable where its content actually
        // draws, so hovering the empty space right of a short note registered as
        // leaving the row and the toolbar flickered away.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Double-click anywhere on the row — not just precisely on the text —
        // enters edit mode. The body carries no `textSelection`, which would
        // otherwise consume the gesture before it ever arrives.
        .onTapGesture(count: 2) { beginEdit() }
    }

    // MARK: - Pieces

    /// Selection outranks hover: a selected row stays tinted while the pointer
    /// moves over its neighbours.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// Click to select. Always visible — a hidden-until-hover checkbox makes the
    /// feed look unselectable, and you cannot see at a glance which rows are
    /// ticked without sweeping the pointer down the list.
    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: Self.checkboxSize, height: Self.checkboxSize)
            .contentShape(Rectangle())
            .pointerButton(onHoverChange: { _ in }) {
                selection.toggleSelected(entry.id)
            }
    }

    /// The checkbox, the timestamp, and the toolbar on one line.
    ///
    /// The checkbox sits inside this row rather than in an outer column so the
    /// stack's own vertical centering aligns it with the timestamp — an outer
    /// top-aligned column left the taller glyph riding low against a 10pt line.
    /// The toolbar holds its space at all times, so revealing it on hover
    /// cannot nudge the timestamp.
    private var headerLine: some View {
        HStack(spacing: Self.gutterSpacing) {
            checkbox
            Text(Self.stamp.string(from: entry.createdAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            toolbar
                .opacity(isHovering && !isEditing ? 1 : 0)
            Spacer(minLength: 0)
        }
    }

    private var bodyText: some View {
        Text(entry.body ?? "")
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .strikethrough(isResolved, color: .secondary)
            .foregroundStyle(isResolved ? .secondary : .primary)
    }

    private var editor: some View {
        GrowingTextEditor(
            text: $editText,
            minHeight: 26,
            maxHeight: 400,
            onSend: { commitEdit() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .focused($editorFocused)
        .onTextEntryKeystrokes { commitEdit() }
        .onExitCommand { isEditing = false }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            CopyButton(text: ItemClipboard.serialize([entry]), iconSize: 11)
            PointerIconButton(
                systemName: isResolved ? "arrow.uturn.backward" : "checkmark",
                help: isResolved ? "Reopen" : "Resolve"
            ) {
                if isResolved {
                    model.unresolve(id: entry.id)
                } else {
                    model.resolve(id: entry.id)
                }
            }
            PointerIconButton(systemName: "trash", help: "Delete") {
                model.delete(id: entry.id)
            }
        }
    }

    // MARK: - Editing

    private func beginEdit() {
        editText = entry.body ?? ""
        isEditing = true
        DispatchQueue.main.async { editorFocused = true }
    }

    /// Save and leave edit mode. An edit emptied to nothing is discarded rather
    /// than saved as a blank note — the delete glyph is how you remove one.
    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != (entry.body ?? "") {
            model.updateBody(id: entry.id, to: trimmed)
        }
        isEditing = false
    }

    private static let checkboxSize: CGFloat = 16
    private static let gutterSpacing: CGFloat = 8
    /// How far the body indents so it starts under the timestamp, not under the
    /// checkbox. Derived from the two above so the column can never drift out of
    /// alignment with the header line.
    private static var gutterWidth: CGFloat { checkboxSize + gutterSpacing }

    /// "Aug 2, 8:57 PM" — enough to place a note in time without a full date.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}
