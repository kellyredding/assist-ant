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
                    : ActionableListSort.less($0.0, $1.0)
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

/// State for the Reschedule panel, shared between the SwiftUI view (presentation
/// + mouse + the typed M/D/Y field) and the window controller's key monitor
/// (Tab/arrows/Return/Esc). Keeping the keyboard model in the controller means
/// the view needs no focus ring of its own. Touched only on the main thread.
final class RescheduleEditorModel: ObservableObject {
    let today: CivilDate
    let presets = RescheduleOption.allCases

    /// 0..<presets.count → a preset is active; == presets.count → "Pick a date…".
    @Published private(set) var activeIndex = 0
    /// The day for "Pick a date…" mode (driven by arrows / the field / clicks).
    @Published private(set) var pickedDate: CivilDate
    /// The month the calendar is showing (first of that month).
    @Published private(set) var displayedMonth: CivilDate
    /// "Pick a date…" resets to today on its FIRST entry only, then remembers.
    private var pickVisited = false

    init(today: CivilDate) {
        self.today = today
        self.pickedDate = today
        self.displayedMonth = RescheduleOption.allCases[0].resolved(from: today).firstOfMonth()
    }

    var pickIndex: Int { presets.count }
    var isPick: Bool { activeIndex == pickIndex }
    /// The day Enter / the Reschedule button applies.
    var resolvedDate: CivilDate {
        isPick ? pickedDate : presets[activeIndex].resolved(from: today)
    }
    /// The calendar can't page before the current month (no past).
    var atEarliestMonth: Bool { displayedMonth <= today.firstOfMonth() }

    /// Select an option row (clamped). Entering "Pick a date…" the first time
    /// resets it to today. The calendar follows the active date's month.
    func activate(_ index: Int) {
        let i = max(0, min(pickIndex, index))
        if i == pickIndex, !pickVisited { pickVisited = true; pickedDate = today }
        activeIndex = i
        displayedMonth = resolvedDate.firstOfMonth()
    }

    func moveSelection(_ delta: Int) { activate(activeIndex + delta) }

    /// Arrow nav on the calendar — only in "Pick a date…". ↑↓ = ±1 week, ←→ =
    /// ±1 day; never before today.
    func nudgeDay(_ days: Int) {
        guard isPick else { return }
        var d = pickedDate.adding(days: days)
        if d < today { d = today }
        pickedDate = d
        displayedMonth = d.firstOfMonth()
    }

    /// Page the displayed month, clamped at the current month.
    func page(_ months: Int) {
        displayedMonth = max(displayedMonth.addingMonths(months), today.firstOfMonth())
    }

    /// Click a day (or type one) — switches to "Pick a date…" and selects it.
    func selectDay(_ date: CivilDate) {
        guard date >= today else { return }
        pickVisited = true
        pickedDate = date
        activeIndex = pickIndex
        displayedMonth = date.firstOfMonth()
    }
}

/// The Reschedule panel body (hosted in RescheduleEditorWindowController): a
/// preset list + an always-visible calendar that previews the highlighted option
/// and goes live on "Pick a date…" (with a typed M/D/Y field). Tab / arrows /
/// Return are driven by the controller's key monitor; this view is presentation,
/// mouse, and the typed field. Monday-first, matching the announce-settings
/// schedule.
struct RescheduleEditorView: View {
    @ObservedObject var model: RescheduleEditorModel
    let onPick: (CivilDate) -> Void
    let onCancel: () -> Void

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// The day under the pointer, for a secondary-shade hover highlight.
    @State private var hoveredDay: CivilDate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reschedule to…")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            VStack(spacing: 2) {
                ForEach(Array(model.presets.enumerated()), id: \.element) { idx, opt in
                    // Single-click selects the option; double-click submits it
                    // outright, mirroring a calendar day's click-to-pick.
                    optionRow(title: opt.title,
                              detail: Self.medium(opt.resolved(from: model.today)),
                              active: model.activeIndex == idx)
                        .pointerButton(
                            action: { model.activate(idx) },
                            doubleAction: { onPick(opt.resolved(from: model.today)) })
                }
                pickRow
            }

            calendar

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Reschedule") { onPick(model.resolvedDate) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // MARK: - Option rows

    private func optionRow(title: String, detail: String, active: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selectionFill(active))
        .contentShape(Rectangle())
    }

    private var pickRow: some View {
        HStack {
            // The label is the clickable region: single-click enters "Pick a
            // date…", double-click submits the date currently set for it —
            // mirroring the presets and the calendar. The stepper stays OUTSIDE
            // this region so the click overlay doesn't swallow its own clicks.
            Text("Pick a date…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .pointerButton(
                    action: { model.activate(model.pickIndex) },
                    doubleAction: { onPick(model.pickedDate) })
            DatePicker(
                "",
                selection: Binding(
                    get: { model.pickedDate.noon },
                    set: { model.selectDay(CivilDate($0)) }),
                in: Calendar.current.startOfDay(for: model.today.noon)...,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .disabled(!model.isPick)
            .opacity(model.isPick ? 1 : 0.4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selectionFill(model.isPick))
    }

    private func selectionFill(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(active ? Color.accentColor.opacity(0.20) : Color.clear)
    }

    // MARK: - Calendar

    private var calendar: some View {
        VStack(spacing: 6) {
            HStack {
                chevron("chevron.left", disabled: model.atEarliestMonth) { model.page(-1) }
                Spacer()
                Text(Self.monthYear(model.displayedMonth))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                chevron("chevron.right", disabled: false) { model.page(1) }
            }
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) { d in
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(gridWeeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in dayCell(day) }
                }
            }
        }
    }

    @ViewBuilder
    private func chevron(_ name: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        let img = Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        if disabled { img } else { img.pointerButton(action: action) }
    }

    @ViewBuilder
    private func dayCell(_ date: CivilDate) -> some View {
        let inMonth = date.month == model.displayedMonth.month && date.year == model.displayedMonth.year
        let isPast = date < model.today
        let isSel = date == model.resolvedDate
        let isToday = date == model.today
        let isHover = hoveredDay == date
        let label = Text("\(date.day)")
            .font(.system(size: 12))
            .foregroundStyle(isSel ? Color.white
                             : (isPast || !inMonth ? Color.secondary : Color.primary))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                ZStack {
                    if isSel {
                        Circle().fill(Color.accentColor).frame(width: 24, height: 24)
                    } else {
                        if isHover {
                            Circle().fill(Color.primary.opacity(0.18)).frame(width: 24, height: 24)
                        }
                        if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1)
                                .frame(width: 24, height: 24)
                        }
                    }
                })
            .contentShape(Rectangle())
        if isPast {
            label
        } else {
            // Single-click selects (updates the field + selection); double-click
            // submits the reschedule for this day.
            label.pointerButton(
                onHoverChange: { hovering in
                    hoveredDay = hovering ? date : (hoveredDay == date ? nil : hoveredDay)
                },
                action: { model.selectDay(date) },
                doubleAction: { onPick(date) })
        }
    }

    private var gridWeeks: [[CivilDate]] {
        let start = model.displayedMonth.firstOfMonth().mondayOfWeek()
        let days = (0..<42).map { start.adding(days: $0) }
        return stride(from: 0, to: 42, by: 7).map { Array(days[$0..<$0 + 7]) }
    }

    private static func medium(_ date: CivilDate) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f.string(from: date.noon)
    }
    private static func monthYear(_ date: CivilDate) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: date.noon)
    }
}
