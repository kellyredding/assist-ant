import Galactic
import SwiftUI

/// Shared metrics for the Scratch pane and its rows, so the composer, the entry
/// count, and each row's checkbox gutter all start on the same vertical line.
/// One definition rather than a literal repeated per view — the alignment is the
/// whole point, and it only holds if they cannot drift apart.
enum ScratchMetrics {
    /// Horizontal inset for everything in the pane.
    static let inset: CGFloat = 12

    /// What `GrowingTextEditor` insets its own text by: `textContainerInset`'s
    /// width (2) plus `NSTextContainer`'s default `lineFragmentPadding` (5).
    ///
    /// Subtracted from `inset` for the composer so its *text* lines up with the
    /// labels beneath it rather than its invisible container edge — padded like
    /// everything else, the placeholder sat 7pt further in than every one of
    /// them.
    static let textViewOwnInset: CGFloat = 7

    /// The composer's leading pad, so its first glyph lands on `inset`.
    static var composerLeading: CGFloat { inset - textViewOwnInset }
}

/// The Scratch tab: a composer pinned at the top, an action bar, then the feed.
///
/// Composer-first rather than a floating "new note" affordance, because the
/// dominant gesture is arriving with something already on the clipboard —
/// select the tab, paste, submit. The composer takes focus the moment the tab
/// becomes selected so that sequence needs no click at all.
struct ScratchPaneView: View {
    @ObservedObject private var model = ScratchModel.shared
    @ObservedObject private var tabs = MainTabNavigator.shared
    @ObservedObject private var selection = ScratchModel.shared.selection
    @ObservedObject private var viewer = ItemViewerModel.shared
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool

    @State private var chords = ScratchListChords()
    /// Whether the composer is taking input.
    ///
    /// An explicit mode rather than "is the field focused", because the pane has
    /// three keyboard owners — the composer, the search box, and the feed's
    /// chords — and exactly one may hold the keys at a time.
    ///
    /// Starts *off*, so arriving at the tab hands the keyboard to the feed and
    /// the chords answer immediately. Auto-focusing the composer on arrival read
    /// as the tab hijacking the keyboard, and cost a press of Escape before any
    /// navigation worked. The submit keystroke is how you ask for the composer.
    @State private var isInputMode = false
    /// Routes Escape between the three owners. A monitor because both text
    /// fields are AppKit views that claim the key before SwiftUI sees it.
    @State private var escapeMonitor: Any?
    /// The submit keystroke, when the feed owns the keyboard, opens the composer.
    @State private var inputModeMonitor: Any?

    private var isEditingRow: Bool { model.editingID != nil }

    /// One line of the composer's 14pt font plus its text-container insets. The
    /// field starts here and grows with its content rather than reserving room
    /// for a note that has not been typed yet.
    private static let composerLineHeight: CGFloat = 26

    /// The size note bodies render at. The composer and the inline row editors
    /// use it too, so text does not change size on the way into a field.
    static let bodyFontSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            actionBar
            Divider()
            feed
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A click anywhere that is not one of the two fields gives the keyboard
        // back to the feed. Applied as a background so it only catches taps the
        // content itself did not handle; rows call `surrenderFields` directly.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { surrenderFields() }
        )
        .onAppear {
            syncChords()
            model.ensureFocus()
            installEscapeMonitor()
            installInputModeMonitor()
        }
        // Selecting the tab enters input mode. Watching the navigator rather
        // than relying on onAppear alone: every pane stays mounted, so onAppear
        // fires once at launch and never again on a tab switch.
        .onChange(of: tabs.selectedTab) { _, tab in
            // Leaving the tab surrenders the keyboard, so returning to it always
            // starts with the feed in charge rather than a stale mode.
            if tab != .scratch { isInputMode = false }
            // Arriving with a focused row means `j`/`k` and `x` answer on the
            // first keystroke. An existing focus is kept — this only fills a gap,
            // so returning to the tab lands where you left off.
            if tab == .scratch { model.ensureFocus() }
            syncChords()
        }
        // Filtering changes which rows exist, so focus has to be reseated the
        // same as on a reload — otherwise it strands on a hidden row that renders
        // no focus bar yet still answers `x`.
        .onChange(of: model.query) { _, _ in model.ensureFocus() }
        .onChange(of: viewer.openItem) { _, _ in syncChords() }
        .onChange(of: model.editingID) { _, _ in syncChords() }
        .onChange(of: isInputMode) { _, _ in syncChords() }
        .onChange(of: searchFocused) { _, _ in syncChords() }
        // Focus leaving the composer takes input mode with it, so the mode and
        // the caret can never disagree about who owns the keyboard.
        .onChange(of: composerFocused) { _, focused in
            if !focused { leaveInputModeKeepingDraft() }
        }
        // ⌘F focuses the search box, matching Find everywhere else. A hidden
        // zero-size button rather than a menu item: Find is already claimed by
        // the terminal's scrollback search, and this only redirects it while the
        // Scratch tab is the one on screen.
        .background(findShortcut)
        .onDisappear {
            chords.remove()
            removeEscapeMonitor()
            removeInputModeMonitor()
        }
    }

    /// ⌘F → search box. Guarded on the tab so it never steals Find from the
    /// terminal.
    private var findShortcut: some View {
        Button("") { focusSearch() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(tabs.selectedTab != .scratch)
    }

    // MARK: - Keyboard ownership

    /// Hand the keys to the composer. Refuses while a row edit holds unsaved
    /// text until the user says what to do with it.
    private func enterInputMode() {
        guardUnsavedEdit {
            searchFocused = false
            isInputMode = true
            // A turn later: the field has to exist and be hit-testable before it
            // can take focus, and on a tab switch this runs while the pane is
            // still transparent.
            DispatchQueue.main.async { composerFocused = true }
        }
    }

    /// Leave input mode, discarding the draft. Escape is a deliberate abandon,
    /// so the half-typed note goes with it rather than lingering invisibly.
    private func exitInputMode() {
        isInputMode = false
        composerFocused = false
        model.draft = ""
    }

    /// Leave input mode because focus went elsewhere — a click on a row, another
    /// field, another pane.
    ///
    /// Keeps the draft, unlike Escape. Losing focus is incidental where Escape is
    /// deliberate, and silently discarding a paste because the pointer moved
    /// would be the worse failure. The resting composer shows the kept draft, so
    /// it is never holding text invisibly.
    private func leaveInputModeKeepingDraft() {
        guard isInputMode else { return }
        isInputMode = false
    }

    /// Give the keyboard back to the feed, keeping whatever the composer held.
    /// The blur is what makes the chords live again.
    private func surrenderFields() {
        searchFocused = false
        composerFocused = false
        leaveInputModeKeepingDraft()
    }

    private func focusSearch() {
        guardUnsavedEdit {
            isInputMode = false
            composerFocused = false
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    /// Run `action`, but if an inline edit holds unsaved text, ask first — every
    /// route out of an edit passes through here, so there is one place that can
    /// lose a change and it always asks.
    private func guardUnsavedEdit(_ action: @escaping () -> Void) {
        guard model.hasUnsavedEdit, let window = SheetAlert.hostWindow() else {
            model.cancelEdit()
            action()
            return
        }
        SheetAlert.confirm(
            in: window,
            message: "Discard changes to this note?",
            detail: "The edit in progress has not been saved.",
            confirm: "Discard",
            onConfirm: {
                model.cancelEdit()
                action()
            }
        )
    }

    // MARK: - Keyboard

    /// Install the chord monitor only while this pane is the live surface and
    /// nothing is being edited. Only one such monitor should be alive at a time:
    /// an inactive one returns the event unhandled, which revives keystrokes the
    /// active surface already consumed.
    private func syncChords() {
        guard tabs.selectedTab == .scratch,
              viewer.openItem == nil,
              !isEditingRow,
              !isInputMode,
              !searchFocused
        else { chords.remove(); return }

        chords.install(.init(
            selection: selection,
            visibleIDs: { model.visibleIDs },
            idsInFocusedGroup: { model.idsInFocusedGroup },
            selectedItems: {
                // Fall back to the focused row when nothing is ticked, so a
                // chord is useful before you have built a selection — the same
                // courtesy the hover toolbar gives the row under the pointer.
                let selected = model.selectedEntries
                if !selected.isEmpty { return selected }
                return model.focusedEntry.map { [$0] } ?? []
            },
            focusedItem: { model.focusedEntry },
            showingCompleted: { model.filter == .completed },
            resolve: { $0.forEach { model.resolve(id: $0.id) } },
            unresolve: { $0.forEach { model.unresolve(id: $0.id) } },
            delete: { $0.forEach { model.delete(id: $0.id) } },
            copy: { ItemClipboard.copy($0) },
            convert: { model.convert($0, to: $1) },
            setListName: { model.setListName($0, to: $1) },
            edit: { model.beginEdit(id: $0.id) }
        ))
    }

    /// Escape hands the keyboard back to the feed, from whichever owner has it.
    ///
    /// A monitor because both text fields are AppKit views that claim Escape
    /// before SwiftUI's `onExitCommand` would see it — and without this the
    /// chords can never fire at all, since the pane arrives in input mode and
    /// the chord monitor stands down while an editable field holds focus.
    ///
    /// Row edits are handled by the row itself, so they are left alone here.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            guard event.keyCode == 53,                       // Escape
                  tabs.selectedTab == .scratch,
                  // While a sheet or an app-modal panel is key, Escape is that
                  // window's to cancel — the list editor runs its own Escape
                  // monitor, and without this gate both fire.
                  NSApp.keyWindow is AssistAntWindow,
                  !isEditingRow
            else { return event }

            if searchFocused {
                searchFocused = false
                return nil
            }
            if isInputMode {
                exitInputMode()
                return nil
            }
            return event
        }
    }

    /// The submit keystroke enters input mode when the feed has the keyboard.
    ///
    /// The same key that commits a note is the one that opens the composer to
    /// write it — and it is free here, because no composer is up to claim it. Read
    /// from the text-entry settings rather than hardcoded, so rebinding submit
    /// moves this with it.
    private func installInputModeMonitor() {
        guard inputModeMonitor == nil else { return }
        inputModeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            // The composer belongs to the main window, so a submit key pressed
            // while a sheet or an app-modal panel is key is not ours — without
            // this the monitor swallows Return from the list editor's Save and
            // from the discard-changes sheet, and opens the composer behind them.
            guard tabs.selectedTab == .scratch,
                  NSApp.keyWindow is AssistAntWindow,
                  !isInputMode, !isEditingRow, !searchFocused,
                  SettingsManager.shared.settings.textEntry
                      .action(for: Keystroke(event: event)) == .submit
            else { return event }
            enterInputMode()
            return nil
        }
    }

    private func removeInputModeMonitor() {
        if let inputModeMonitor { NSEvent.removeMonitor(inputModeMonitor) }
        inputModeMonitor = nil
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - Composer

    /// `fixedSize` vertically is what keeps this one line tall. The editor
    /// reports a clamped intrinsic height, but a representable in a flexible
    /// stack otherwise accepts whatever height it is offered — which is how it
    /// came to swallow the pane.
    @ViewBuilder
    private var composer: some View {
        if isInputMode {
            HStack(alignment: .top, spacing: 6) {
                GrowingTextEditor(
                    text: $model.draft,
                    placeholder: "Paste or type a note…",
                    minHeight: Self.composerLineHeight,
                    fontSize: Self.bodyFontSize,
                    maxHeight: 260,
                    onSend: { model.submitDraft() }
                )
                .fixedSize(horizontal: false, vertical: true)
                .focused($composerFocused)
                PointerIconButton(systemName: "xmark.circle",
                                  help: "Cancel (esc)") {
                    exitInputMode()
                }
            }
            .padding(.leading, ScratchMetrics.composerLeading)
            .padding(.trailing, ScratchMetrics.inset)
            .padding(.vertical, 8)
            // Only live while this is the composer taking input. Two text-entry
            // monitors in one window both consume the submit keystroke and race
            // for it, which is why an inline row edit stood the composer down
            // rather than sharing the key.
            .onTextEntryKeystrokes(enabled: !isEditingRow) {
                model.submitDraft()
            }
        } else {
            restingComposer
        }
    }

    /// Out of input mode the composer is a prompt, not a field — so Escape has
    /// somewhere visible to have landed, and clicking it gets back in.
    private var restingComposer: some View {
        HStack(spacing: 6) {
            // A draft kept through a focus loss is shown here rather than hidden
            // behind the placeholder, so the composer is never holding text you
            // cannot see.
            Text(model.draft.isEmpty
                 ? "Paste or type a note…"
                 : model.draft.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: Self.bodyFontSize))
                .foregroundStyle(model.draft.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(restingHint)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
        .padding(.leading, ScratchMetrics.inset)
        .padding(.trailing, ScratchMetrics.inset)
        .frame(height: Self.composerLineHeight)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { enterInputMode() }
    }

    // MARK: - Action bar

    /// Count on the left, the batch toolbar beside it once something is
    /// selected, and the feed toggle on the right.
    ///
    /// The batch toolbar lives here rather than floating over the feed so it
    /// never covers a row, and so its appearance cannot shift the rows beneath
    /// it — this bar's height is the same whether or not anything is selected.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(countLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)

            // Gated on the acted-on set, not on `hasSelection`: a fold can hide
            // every ticked note, and a bar over nothing offers buttons that
            // cannot fire. The ticks survive the fold and the bar returns with
            // the group.
            if !model.selectedEntries.isEmpty {
                batchToolbar
            }

            Spacer(minLength: 8)

            searchField

            Picker("", selection: $model.filter) {
                ForEach(ScratchModel.Filter.allCases, id: \.self) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        .padding(.horizontal, ScratchMetrics.inset).padding(.vertical, 6)
        .frame(height: 34)
    }

    /// Filters the feed as you type. Deliberately not auto-focused — the
    /// composer owns arrival focus, since pasting is the common gesture and
    /// searching is the occasional one.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .onSubmit {}
            if !model.query.isEmpty {
                PointerIconButton(systemName: "xmark.circle.fill",
                                  help: "Clear search") {
                    model.query = ""
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .frame(width: 200)
    }

    private var batchToolbar: some View {
        // Resolved once: the count and every control below must agree on what
        // they are acting on, and the property recomputes the whole filtered feed
        // on each read. `selectedIDs` would count notes a folded group is hiding.
        let selected = model.selectedEntries
        return HStack(spacing: 6) {
            Text("\(selected.count) selected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            CopyButton(text: ItemClipboard.serialize(selected))
            PointerIconButton(
                systemName: model.filter == .completed
                    ? "arrow.uturn.backward" : "checkmark",
                help: model.filter == .completed
                    ? "Reopen selected" : "Resolve selected"
            ) {
                if model.filter == .completed {
                    model.unresolveSelected()
                } else {
                    model.resolveSelected()
                }
            }
            PointerIconButton(systemName: "trash", help: "Delete selected") {
                model.deleteSelected()
            }
            // Mnemonics on: `l t` / `l r` / `l e` and `l l` are live exactly when
            // this bar is, so the menu underlines the letters that fire them.
            // Sits before Clear selection, which stays last as the only meta
            // action here.
            ScratchRowMenu(notes: selected,
                           showsMnemonics: true,
                           convert: { model.convert($0, to: $1) },
                           setListName: { model.setListName($0, to: $1) })
            PointerIconButton(systemName: "xmark", help: "Clear selection") {
                selection.clearSelection()
            }
        }
    }

    /// Shows the filtered count against the total while a query narrows the
    /// feed, so a small number never reads as "most of my notes vanished".
    /// Names the keys that get you in, read from the text-entry settings so a
    /// rebound submit key is advertised correctly.
    private var restingHint: String {
        if !model.draft.isEmpty { return "draft kept" }
        let submit = SettingsManager.shared.settings.textEntry.submitHint
        return submit.map { "\($0) to write · ⌘F to search" }
            ?? "⌘F to search"
    }

    private var countLabel: String {
        let shown = model.rows.count
        let total = model.entries.count
        if !model.query.isEmpty, shown != total {
            return "\(shown) of \(total)"
        }
        return shown == 1 ? "1 entry" : "\(shown) entries"
    }

    // MARK: - Feed

    @ViewBuilder
    private var feed: some View {
        // Keyed on the groups rather than the rows: the groups are what the feed
        // renders, and a group with no matching notes never exists — so "no
        // groups" is exactly "nothing to show", with no bare headers possible.
        if model.groups.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { group in
                            ScratchListSection(
                                group: group,
                                isCollapsed: model.isCollapsed(group.id),
                                onToggle: { model.toggleCollapse($0) },
                                model: model,
                                onInteract: { surrenderFields() }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                // Keep the keyboard-focused row on screen as j/k walk past the
                // viewport edge — the focus bar is useless if you cannot see it.
                // A collapsed group renders no rows, so an id inside one resolves
                // to nothing and this is a no-op; navigation never seats focus
                // there, so the no-op case is unreachable by keystroke.
                .onChange(of: selection.focusedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if !model.query.isEmpty {
                Text("No notes match “\(model.query)”")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Clear the search to see the rest.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.filter == .open
                     ? "Nothing parked yet"
                     : "Nothing completed yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.filter == .open
                     ? "Paste or type a note above."
                     : "Resolved notes collect here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
