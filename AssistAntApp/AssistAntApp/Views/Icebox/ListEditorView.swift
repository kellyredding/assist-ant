import AppKit
import SwiftUI

/// The "List" editor body (hosted in ListEditorWindowController's window): a
/// combo-box-style field over the known list names plus the CTA row. Save
/// commits the typed name (known → reuse, unknown → a new name); Remove (shown
/// only when the item already has a list) clears it. Layout mirrors Galaxy's
/// New-marker sheet, with the danger Remove control bottom-left and Cancel +
/// Save trailing.
struct ListEditorView: View {
    let currentListName: String?
    let knownNames: [String]
    let onSave: (String) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        currentListName: String?,
        knownNames: [String],
        onSave: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentListName = currentListName
        self.knownNames = knownNames
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _text = State(initialValue: currentListName ?? "")
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("List name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                FuzzyComboField(
                    text: $text,
                    options: knownNames,
                    placeholder: "e.g. Backlog, Ideas, Follow-ups",
                    onSubmit: { if !trimmed.isEmpty { onSave(trimmed) } }
                )
            }

            HStack {
                if currentListName != nil {
                    // .destructive role alone doesn't redden a window button on
                    // macOS, so tint it red explicitly; the trash glyph reads as
                    // danger at a glance.
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove from list", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// A combo-box-style field that looks native — a bordered text field with a
/// disclosure chevron — backed by a dropdown that filters the options FUZZILY
/// and live as you type (so "opex" finds "💰 Opex" behind the emoji). ↑/↓ move
/// the highlight, Return accepts the highlighted match or submits, a click
/// selects, and the chevron toggles the full list. Built in SwiftUI because
/// NSComboBox can't open its list as you type. The editor window grows to fit
/// the dropdown (it's in-flow), so it's never clipped.
struct FuzzyComboField: View {
    @Binding var text: String
    let options: [String]
    var placeholder: String = ""
    var onSubmit: () -> Void = {}

    @State private var isOpen = false
    @State private var highlighted = 0
    /// Set when we write `text` programmatically (selecting a row), so the
    /// text-change handler doesn't treat it as typing and re-open the list.
    @State private var suppressOpen = false
    @FocusState private var focused: Bool

    private var matches: [String] { ListFuzzy.filter(options, query: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if isOpen && !matches.isEmpty { dropdown }
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: text) { _, _ in
                    if suppressOpen { suppressOpen = false }
                    else { isOpen = true; highlighted = 0 }
                }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.return) { commitOrSubmit() }
            Button { isOpen.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var dropdown: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element) { idx, name in
                        Text(name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .foregroundStyle(idx == highlighted ? Color.white : Color.primary)
                            .background(idx == highlighted ? Color.accentColor : Color.clear)
                            .contentShape(Rectangle())
                            .id(idx)
                            .onHover { if $0 { highlighted = idx } }
                            .onTapGesture { select(name) }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .onChange(of: highlighted) { _, h in proxy.scrollTo(h) }
        }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        isOpen = true
        highlighted = max(0, min(matches.count - 1, highlighted + delta))
        return .handled
    }

    private func commitOrSubmit() -> KeyPress.Result {
        if isOpen, matches.indices.contains(highlighted), matches[highlighted] != text {
            select(matches[highlighted])
        } else {
            isOpen = false
            onSubmit()
        }
        return .handled
    }

    private func select(_ name: String) {
        suppressOpen = true
        text = name
        isOpen = false
    }
}

/// Case-insensitive fuzzy ranking for the combo field: prefix beats substring
/// beats subsequence; non-matches drop. A leading emoji in the name is just
/// extra characters to skip, so typing the text part still matches. An empty
/// query returns every option.
enum ListFuzzy {
    static func filter(_ names: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return names }
        return names
            .compactMap { name -> (String, Int)? in
                guard let score = score(name.lowercased(), q) else { return nil }
                return (name, score)
            }
            .sorted {
                $0.1 != $1.1
                    ? $0.1 < $1.1
                    : $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
            }
            .map(\.0)
    }

    private static func score(_ name: String, _ q: String) -> Int? {
        if name.hasPrefix(q) { return 0 }
        if name.contains(q) { return 1 }
        return isSubsequence(q, of: name) ? 2 : nil
    }

    private static func isSubsequence(_ q: String, of name: String) -> Bool {
        var qi = q.startIndex
        for ch in name {
            guard qi < q.endIndex else { break }
            if ch == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex
    }
}
