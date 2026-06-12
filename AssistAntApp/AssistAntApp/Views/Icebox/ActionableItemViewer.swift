import AppKit
import SwiftUI

/// The two fields editable in the actionable reader. The key monitor in
/// IceboxPaneView toggles focus between them on Tab / ⇧Tab.
enum ActionableEditField: Hashable { case title, body }

/// The edit session for the actionable reader, owned by the stable host
/// (IceboxPaneView) so the pane's key monitor can drive save / cancel / focus
/// without reaching into a view that unmounts. The viewer renders against it
/// and mirrors `focus` into its own `@FocusState`. Title + body are the only
/// user-editable text; everything else stays read-only context.
@MainActor
final class ActionableEditSession: ObservableObject {
    @Published var isEditing = false
    @Published var title = ""
    @Published var body = ""
    @Published var isSaving = false
    @Published var focus: ActionableEditField?

    /// A blank title can't be saved (an item must keep a title); saving is also
    /// blocked mid-write so a double ⌘↵ can't fire twice.
    var canSave: Bool {
        !isSaving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func begin(title: String, body: String) {
        self.title = title
        self.body = body
        isSaving = false
        isEditing = true
        focus = .title       // title-first; Tab moves to the body
    }

    func cancel() {
        isEditing = false
        isSaving = false
        focus = nil
        title = ""
        body = ""
    }

    func finishSaving() {
        isSaving = false
        isEditing = false
        focus = nil
    }
}

/// Full-takeover reader for a single actionable item, shown inside the Icebox
/// tab in place of the list. A control-bar header (title + the same item
/// actions a list row exposes + close), a metadata line (kind · list ·
/// iceboxed date · link), then the scrollable markdown body. In edit mode the
/// title becomes a text field and the body a plain-text editor over the raw
/// markdown, with a Save / Cancel footer. The edit session and the keystroke
/// handling live up in IceboxPaneView; this view renders against the session
/// and calls back for begin / cancel / save. `onItemChange` carries a
/// post-action item back so a Done / Move / reclassify reflects in place.
struct ActionableItemViewer: View {
    let item: Item
    @ObservedObject var edit: ActionableEditSession
    let onClose: () -> Void
    var onItemChange: (Item) -> Void = { _ in }
    var onBeginEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var onSave: () -> Void = {}

    @FocusState private var fieldFocus: ActionableEditField?

    /// A resolved (done/dismissed) item reads as struck-through and dimmed in
    /// the reader, mirroring the list row — a settled item still opens, it just
    /// shows as complete.
    private var isResolved: Bool { item.resolvedAt != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            metaBar
            if edit.isEditing {
                editor
            } else {
                EventBodyTextView(markdown: item.body ?? "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The body renders its own text colors, so opacity (not a
                    // foreground style) is what mutes the whole resolved block —
                    // matching the dimmed, secondary title above it.
                    .opacity(isResolved ? 0.5 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
        // edit.focus is the source of truth: it drives the title via
        // @FocusState and the body via the representable. Report focus back
        // only on *gain* — when the body grabs first responder, fieldFocus goes
        // nil, and we must not let that clobber the session's .body.
        .onChange(of: edit.focus) { _, f in
            // Defer the title focus a tick: entering edit creates the title
            // field in the same render that sets focus, and assigning
            // @FocusState before the field exists is dropped on the floor.
            if f == .title {
                DispatchQueue.main.async { fieldFocus = .title }
            } else {
                fieldFocus = nil
            }
        }
        .onChange(of: fieldFocus) { _, f in if edit.isEditing, f == .title { edit.focus = .title } }
    }

    // A control bar: title on the left, then the row actions + the edit toggle,
    // then close. In edit mode the title turns into a text field and the row
    // actions + pencil step aside — the only chrome is the editor's Save /
    // Cancel (plus close). Dismissed by ✕ or Escape.
    private var header: some View {
        HStack(spacing: 10) {
            if edit.isEditing {
                TextField("Title", text: $edit.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused($fieldFocus, equals: .title)
                    .onSubmit { edit.focus = .body }
                    .frame(maxWidth: .infinity)
            } else {
                Text(item.title)
                    .font(.headline).lineLimit(1).truncationMode(.tail)
                    .strikethrough(isResolved)
                    .foregroundStyle(isResolved ? .secondary : .primary)
                Spacer(minLength: 12)
                ItemActions(items: [item], onChange: onItemChange)
                PointerIconButton(
                    systemName: "square.and.pencil", help: "Edit (⌘↵)",
                    action: onBeginEdit
                )
            }
            PointerIconButton(
                systemName: "xmark", help: "Close (Esc)", action: onClose
            )
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    private var metaBar: some View {
        HStack(spacing: 8) {
            KindBadge(item: item)
            if !metaText.isEmpty {
                Text(metaText)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let url = item.actionableExternalURL, let u = URL(string: url) {
                PointerIconButton(
                    systemName: "arrow.up.right.square",
                    help: "Open link in browser",
                    action: { NSWorkspace.shared.open(u) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // The body swapped for a plain-text editor over the raw markdown source,
    // wrapped in a focus-highlighting border that mirrors the title field, with
    // a Save / Cancel footer. Save is disabled while a write is in flight or the
    // title is blank; a spinner replaces it during the (local, synchronous)
    // write, matching the load affordance the Icebox uses.
    private var editor: some View {
        VStack(spacing: 0) {
            ActionableBodyEditor(
                text: $edit.body,
                isFocused: edit.focus == .body,
                onFocusGained: { if edit.isEditing { edit.focus = .body } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color(.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    edit.focus == .body ? Color.accentColor : Color(.separatorColor),
                    lineWidth: edit.focus == .body ? 2 : 1
                )
            )
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .disabled(edit.isSaving)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            CapsuleActionButton(title: "Cancel", action: onCancelEdit)
                .opacity(edit.isSaving ? 0.4 : 1)
                .disabled(edit.isSaving)
            if edit.isSaving {
                ProgressView().scaleEffect(0.6).frame(width: 56, height: 22)
            } else {
                CapsuleActionButton(title: "Save", action: onSave)
                    .opacity(edit.canSave ? 1 : 0.4)
                    .disabled(!edit.canSave)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    /// List name and iceboxed date, joined with a middot — the non-badge meta.
    private var metaText: String {
        var parts: [String] = []
        if let list = item.actionableListName { parts.append(list) }
        if let at = item.iceboxedAt {
            parts.append("Iceboxed \(Self.dateFormatter.string(from: at))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

/// Editable plain-text body editor for the actionable reader — an AppKit
/// NSTextView (SwiftUI's TextEditor exposes no caret control). On programmatic
/// focus (Tab into the body) it drops the caret at the top; a mouse click keeps
/// its natural caret position. Focus gain is reported back so the edit session
/// and the focus highlight stay in sync. Edits the raw markdown source.
struct ActionableBodyEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var onFocusGained: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = FocusReportingTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.focusRingType = .none           // the SwiftUI overlay draws the highlight
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        tv.delegate = context.coordinator
        tv.onFocusGained = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onFocusGained()
        }
        context.coordinator.textView = tv
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? FocusReportingTextView else { return }
        if tv.string != text { tv.string = text }
        // Drive focus from the model. Only when we *programmatically* take first
        // responder (Tab / model) do we reset the caret to the top — a click
        // arrives already-first-responder, so this skips and keeps its caret.
        if isFocused {
            DispatchQueue.main.async {
                guard let window = tv.window, window.firstResponder !== tv else { return }
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ActionableBodyEditor
        weak var textView: FocusReportingTextView?
        init(_ parent: ActionableBodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// NSTextView that reports when it gains first responder, so the reader can
/// reflect a click-into-body in the edit session and the focus highlight.
final class FocusReportingTextView: NSTextView {
    var onFocusGained: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusGained?() }
        return ok
    }
}
