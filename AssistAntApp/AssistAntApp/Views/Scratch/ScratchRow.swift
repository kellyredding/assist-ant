import AppKit
import SwiftUI

/// One entry in the scratch feed: a keyboard-focus bar, a selection checkbox,
/// the timestamp with the hover toolbar beside it, and the body beneath.
///
/// The body renders as plain text, not Markdown. Scratch holds verbatim parked
/// values — ids, URLs, code fragments — and Markdown would silently eat the
/// `*`, `_`, and `#` in them. Rendering raw is both truer to what was pasted and
/// what makes the search highlight tractable, since the highlight works in
/// character offsets a rendered tree would have moved.
///
/// No detail view: double-click, or Return on the focused row, edits in place.
struct ScratchRow: View {
    let row: ScratchModel.Row
    @ObservedObject var model: ScratchModel
    /// Observed separately from `model`, and that is the point: the selection is
    /// its own `ObservableObject` that the model merely holds, so observing the
    /// model does not subscribe to it. Without this the checkbox, the focus bar,
    /// and the row tint only refreshed when some *other* state change forced a
    /// re-render — moving the pointer off the row.
    @ObservedObject var selection: ActionableSelection

    /// Called on any click in this row, so the pane can take focus off its text
    /// fields. A row handles its own taps, so the pane's background gesture never
    /// sees them — without this, clicking a row left the composer focused and the
    /// chords inert.
    let onInteract: () -> Void

    init(row: ScratchModel.Row, model: ScratchModel,
         onInteract: @escaping () -> Void) {
        self.row = row
        self.model = model
        self.onInteract = onInteract
        self._selection = ObservedObject(wrappedValue: model.selection)
    }

    @State private var isHovering = false
    @FocusState private var editorFocused: Bool

    private var entry: Item { row.item }
    private var isResolved: Bool { entry.resolvedAt != nil }
    private var isSelected: Bool { selection.selectedIDs.contains(entry.id) }
    private var isFocused: Bool { selection.focusedItemID == entry.id }
    private var isEditing: Bool { model.editingID == entry.id }

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
        // Keyboard-focus bar: a row-height leading overlay rather than a
        // flexible sibling, matching the index surfaces — an overlay is handed
        // the row's already-resolved height, so the bar spans it exactly.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isFocused ? Color.accentColor : Color.clear)
                .frame(width: 3)
        }
        // Without this the row is only hit-testable where its content actually
        // draws, so hovering the empty space right of a short note registered as
        // leaving the row and the toolbar flickered away.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Double-click anywhere on the row — not just precisely on the text —
        // enters edit mode. The body carries no `textSelection`, which would
        // otherwise consume the gesture before it ever arrives.
        .onTapGesture(count: 2) {
            onInteract()
            beginEdit()
        }
        // A single click seats keyboard focus here, so j/k continue from where
        // the pointer last was rather than from wherever focus was stranded.
        .onTapGesture {
            onInteract()
            selection.focus(entry.id)
        }
        .onChange(of: isEditing) { _, editing in
            if editing { focusEditor() }
        }
        // Also on appear: a row that re-mounts already being edited — which a
        // feed refresh does — never sees the change, and would come back with an
        // unfocused editor.
        .onAppear { if isEditing { focusEditor() } }
    }

    // MARK: - Pieces

    /// Selection outranks hover: a selected row stays tinted while the pointer
    /// moves over its neighbours. Opacities match the index surfaces.
    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.10) }
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
                onInteract()
                selection.focus(entry.id)
                selection.toggleSelected(entry.id)
            }
    }

    /// The checkbox, the timestamp, and the toolbar on one line.
    ///
    /// The checkbox sits inside this row rather than in an outer column so the
    /// stack's own vertical centering aligns it with the timestamp — an outer
    /// top-aligned column left the taller glyph riding low against a 10pt line.
    /// The toolbar holds its space at all times, so revealing it on hover cannot
    /// nudge the timestamp.
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
        Text(highlighted)
            .font(.system(size: ScratchPaneView.bodyFontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .strikethrough(isResolved, color: .secondary)
    }

    /// The body with the search's matched characters tinted.
    ///
    /// Built from the character offsets the model already computed, so the match
    /// never runs twice and the view cannot disagree with the filter about what
    /// matched. An empty query yields no offsets and this is a plain string.
    private var highlighted: AttributedString {
        var text = AttributedString(entry.body ?? "")
        text.foregroundColor = isResolved ? .secondary : .primary
        guard !row.matchedOffsets.isEmpty else { return text }

        // Walked once rather than indexed per offset: `AttributedString` has no
        // bounds-limited character offsetting, so stepping to an arbitrary
        // offset risks running past the end. Advancing character by character
        // is bounds-safe by the loop condition and single-pass either way.
        let targets = Set(row.matchedOffsets)
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let next = text.index(afterCharacter: index)
            if targets.contains(offset) {
                text[index..<next].backgroundColor = .yellow.opacity(0.35)
                text[index..<next].foregroundColor = .primary
            }
            index = next
            offset += 1
        }
        return text
    }

    /// Bound straight to the model's draft, so the text survives a re-mount and
    /// the pane can see whether abandoning it would lose anything.
    private var editor: some View {
        HStack(alignment: .top, spacing: 6) {
            GrowingTextEditor(
                text: $model.editDraft,
                minHeight: 26,
                fontSize: ScratchPaneView.bodyFontSize,
                maxHeight: 400,
                onSend: { model.commitEdit() }
            )
            .fixedSize(horizontal: false, vertical: true)
            .focused($editorFocused)
            PointerIconButton(systemName: "xmark.circle",
                              help: "Cancel (esc)") {
                model.cancelEdit()
            }
        }
        // Only the editing row's monitor is live, so it cannot race the pane
        // composer's for the submit keystroke.
        .onTextEntryKeystrokes(enabled: isEditing) { model.commitEdit() }
        .onExitCommand { model.cancelEdit() }
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

    private func beginEdit() { model.beginEdit(id: entry.id) }

    /// Seat keyboard focus in the editor. The text itself is already in the
    /// model, so this only has to claim focus.
    private func focusEditor() {
        DispatchQueue.main.async { editorFocused = true }
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
