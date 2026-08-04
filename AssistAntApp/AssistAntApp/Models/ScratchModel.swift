import Combine
import Foundation

/// Drives the Scratch tab.
///
/// Live-observed rather than snapshot-and-refresh like the Icebox and Schedule
/// models. Those hold a snapshot so an accidental Done can be undone before the
/// row disappears; the scratch feed is the opposite case — you submit into it
/// constantly and expect the entry to appear the instant you commit it, so the
/// feed follows the database directly.
///
/// The draft lives here rather than in the view so switching tabs mid-thought
/// does not discard a half-typed note.
@MainActor
final class ScratchModel: ObservableObject {
    static let shared = ScratchModel()

    /// Which feed is showing. Open is the working buffer; completed is the
    /// review list. The two are disjoint.
    enum Filter: String, CaseIterable {
        case open
        case completed

        var title: String {
            switch self {
            case .open: return "Open"
            case .completed: return "Completed"
            }
        }

        var isResolved: Bool { self == .completed }
    }

    @Published var filter: Filter = .open {
        didSet {
            guard oldValue != filter else { return }
            // The two feeds are disjoint, so a selection carried across would
            // reference entries the new feed cannot show — and an open editor
            // would belong to a row this feed does not contain, which is how it
            // came back blank and still focused.
            selection.clearSelection()
            cancelEdit()
            // Collapse is deliberately NOT cleared: it is keyed by list name,
            // which is the one thing the two feeds have in common, so a list you
            // folded away stays folded when you flip between them.
            subscribe()
        }
    }

    /// The row being edited in place, and its in-progress text.
    ///
    /// Both live here rather than in the row's own `@State` for two reasons: the
    /// pane needs to know whether an abandoned edit would lose changes before it
    /// lets a filter switch or a search discard it, and a row that re-mounts —
    /// which a filter switch does — would otherwise come back with an empty
    /// editor because its `@State` reset while the id said it was still editing.
    @Published private(set) var editingID: String?
    @Published var editDraft: String = ""
    @Published private(set) var entries: [Item] = []
    /// The composer's live text. Held across tab switches on purpose.
    @Published var draft: String = ""
    /// The search box. Filters the feed without touching what is stored, so
    /// clearing it restores every entry.
    @Published var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            // Same reasoning as the filter: narrowing can hide the row being
            // edited, and an editor attached to a row you cannot see is a trap.
            cancelEdit()
            // Focus and selection are expressed against the *visible* rows, so
            // narrowing the feed can strand either on a row that is no longer
            // shown. Reconciling against the new visible set reseats focus on
            // the first match; `present` is every note the query matched —
            // including the ones a collapsed group holds — so folding a group
            // away does not quietly drop its ticks.
            selection.reconcile(visible: visibleIDs, present: Set(rows.map(\.id)))
        }
    }
    /// Selection + keyboard focus, for the batch actions that arrive with the
    /// chords. Present now so the row views can read it from the start.
    let selection = ActionableSelection()

    /// Collapsed groups, by group id — a list name, or the no-list group's
    /// sentinel.
    ///
    /// One set across both feeds, the way Schedule's is one set across every day
    /// — "applies across days", as `ScheduleAgendaModel` puts it. The Open and
    /// Completed feeds hold disjoint notes, which is why a selection and an open
    /// editor cannot survive the switch; a collapse is keyed by *list name*,
    /// which is the one thing the two feeds share. Folding "Opex" away twice to
    /// stop looking at it would be the surprise.
    ///
    /// In memory for the session, like every index surface's: it survives tab
    /// switches (this is a singleton) but not a relaunch.
    @Published private(set) var collapsedLists: Set<String> = []

    private let store: ItemStore
    private var feedObserver: AnyCancellable?

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        subscribe()
    }

    private func subscribe() {
        feedObserver = store.observeScratch(resolved: filter.isResolved)
            .replaceError(with: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.entries = items
                // Drop ids that have left the feed — resolved, deleted, or
                // converted — so a stale selection can't keep the batch toolbar
                // up over rows that are gone. Reconciled against the *visible*
                // rows rather than everything fetched, so focus lands on a row
                // the query actually shows.
                // `visible` skips collapsed groups so focus lands somewhere the
                // feed actually draws; `present` is every matched note, so a
                // fold does not drop its ticks.
                self.selection.reconcile(
                    visible: self.visibleIDs,
                    present: Set(self.rows.map(\.id)))
            }
    }

    /// One visible row: the entry plus where the query matched its body, so the
    /// view highlights without re-running the match itself.
    struct Row: Identifiable {
        let item: Item
        let matchedOffsets: [Int]
        var id: String { item.id }
    }

    /// The feed as shown: filtered by the query, still newest-first.
    ///
    /// Ordering deliberately ignores match score. This is a chronological
    /// buffer, and resorting it by relevance while typing would move a note out
    /// from under the pointer — the feed's order is part of how you remember
    /// where something was.
    var rows: [Row] {
        entries.compactMap { item in
            // Word-scoped: notes are prose, and a subsequence allowed to span
            // words matches nearly every note, which makes the filter useless.
            // A space in the query opts back into spanning, one term per word.
            guard let match = FuzzyMatch.result(
                item.body ?? "", query: query, scope: .terms)
            else { return nil }
            return Row(item: item, matchedOffsets: match.matchedOffsets)
        }
    }

    /// The feed's groups as the pane renders them — spelled once, since a
    /// generic instantiation in a view signature reads as noise.
    typealias RowGroup = ScratchGroup<Row>

    /// The feed as sections: the unfiled notes first, then each list. Derived
    /// from `rows`, so grouping sees exactly what the query left visible and the
    /// match offsets ride along into the group they land in.
    var groups: [RowGroup] {
        ScratchGrouping.groups(rows) { $0.item.scratchListName }
    }

    /// Visible ids in display order — each group's notes top→bottom, skipping
    /// the notes inside a collapsed group. What `j`/`k` step through, what `x`
    /// will toggle, and the order a batch acts in.
    var visibleIDs: [String] {
        groups.flatMap { group -> [String] in
            if collapsedLists.contains(group.id) { return [] }
            return group.entries.map(\.id)
        }
    }

    /// The ids of every note in the group holding keyboard focus — `* a`'s
    /// target. Empty when focus sits nowhere visible, including inside a
    /// collapsed group: a keystroke may not produce a selection that renders
    /// nowhere. Same rule as `ActionableListNavigation.idsInGroup`, reproduced
    /// rather than shared because that helper is typed on groups of `Item` and
    /// these hold rows that carry their match offsets too.
    var idsInFocusedGroup: [String] {
        guard let focused = selection.focusedItemID,
              let group = groups.first(where: { g in
                  !collapsedLists.contains(g.id)
                      && g.entries.contains { $0.id == focused }
              })
        else { return [] }
        return group.entries.map(\.id)
    }

    /// The selected entries, in feed order. Scoped to the visible rows, so a
    /// batch action can never touch a note the query has hidden or a collapsed
    /// group holds — the same scoping
    /// `ActionableSelection.selectedItems(in:collapsed:)` applies on the index
    /// surfaces.
    var selectedEntries: [Item] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.item) })
        return visibleIDs
            .filter(selection.selectedIDs.contains)
            .compactMap { byID[$0] }
    }

    /// The note `j`/`k` focus sits on, if it is actually on screen.
    ///
    /// Guarded on the visible set rather than merely on `rows`, because two
    /// paths read it. The chords fall back to the focused note when nothing is
    /// ticked, so `l l` or `a d` could act on a note that renders nowhere; and
    /// bare Return opens the inline editor on it, which inside a folded group
    /// puts the feed into an editing state with no editor on screen. The index
    /// surfaces need neither guard — their Return opens the reader, which shows
    /// what it acted on — so this is a guard for keystrokes they do not have.
    /// Refusing is the same trade `toggleSelectedFocused` already makes.
    var focusedEntry: Item? {
        guard let id = selection.focusedItemID, visibleIDs.contains(id)
        else { return nil }
        return rows.first { $0.id == id }?.item
    }

    /// Fold a group away, or unfold it. Keyed by group id so a named list and
    /// the no-list group fold through one mechanism and the sentinel never
    /// enters the real list-name space.
    func toggleCollapse(_ groupID: String) {
        if collapsedLists.contains(groupID) {
            collapsedLists.remove(groupID)
        } else {
            collapsedLists.insert(groupID)
        }
    }

    func isCollapsed(_ groupID: String) -> Bool {
        collapsedLists.contains(groupID)
    }

    /// Make sure a visible row carries focus, so `j`/`k` and `x` have somewhere
    /// to act the instant the feed is on screen.
    ///
    /// Called on arriving at the tab and whenever the query changes, not only on
    /// a reload. Filtering removes rows exactly as a reload does, and focus left
    /// on a row the query has hidden renders nothing while still answering to
    /// `x` — a selection with no row to show it.
    func ensureFocus() { selection.ensureFocus(in: visibleIDs) }

    // MARK: - Inline editing

    /// True when the open editor holds text differing from what is stored — the
    /// only case where abandoning it actually costs anything.
    var hasUnsavedEdit: Bool {
        guard let editingID,
              let entry = entries.first(where: { $0.id == editingID })
        else { return false }
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (entry.body ?? "")
    }

    func beginEdit(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        selection.focus(id)
        editDraft = entry.body ?? ""
        editingID = id
    }

    /// Save the open edit and close the editor. An edit emptied to nothing is
    /// discarded rather than stored as a blank note — the delete glyph is how you
    /// remove one.
    func commitEdit() {
        guard let id = editingID else { return }
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = entries.first(where: { $0.id == id })?.body ?? ""
        if !trimmed.isEmpty, trimmed != original {
            updateBody(id: id, to: trimmed)
        }
        cancelEdit()
    }

    /// Close the editor, discarding whatever it held.
    func cancelEdit() {
        editingID = nil
        editDraft = ""
    }

    // MARK: - Batch actions

    /// Resolve or reopen every selected entry, then clear the selection — the
    /// rows are about to leave this feed, so holding their ids would strand the
    /// toolbar over nothing.
    func resolveSelected() {
        let ids = selectedEntries.map(\.id)
        selection.clearSelection()
        for id in ids { resolve(id: id) }
    }

    func unresolveSelected() {
        let ids = selectedEntries.map(\.id)
        selection.clearSelection()
        for id in ids { unresolve(id: id) }
    }

    func deleteSelected() {
        let ids = selectedEntries.map(\.id)
        selection.clearSelection()
        for id in ids { delete(id: id) }
    }

    /// Set or clear the list on a set of notes, then drop the ones that moved
    /// from the selection.
    ///
    /// No regroup and no reconcile here, unlike `ScheduleAgendaModel.setListName`:
    /// that model holds a snapshot it has to re-bucket by hand, while this feed
    /// is live — `observeScratch` re-emits and `subscribe`'s `reconcile` reseats
    /// focus if a note landed in a group that is folded away. Deselecting is
    /// still ours to do: the rows moved, and a list assignment that left them
    /// ticked in their new group would read as unfinished.
    ///
    /// Only the notes actually written are deselected, matching Schedule — a note
    /// whose write failed stays ticked, so the retry is one keystroke rather than
    /// a hunt for which of a batch silently did not move. That is why this loops
    /// by hand instead of going through `perform`, which cannot report per item.
    func setListName(_ items: [Item], to listName: String?) {
        var written: [String] = []
        for item in items {
            do {
                try store.setScratchListName(id: item.id, to: listName)
                written.append(item.id)
            } catch {
                AssistAntLog.info(
                    "scratch: setListName failed for \(item.id) — \(error)")
            }
        }
        selection.deselect(written)
    }

    // MARK: - Actions

    /// Commit the draft as a new entry and clear it.
    ///
    /// A blank draft is a no-op rather than an empty note: the submit keystroke
    /// is easy to hit twice, and the second press should do nothing.
    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        add(text)
        draft = ""
    }

    func add(_ text: String) {
        // Same resolution the socket ingest paths use — the workspace row is
        // the source of the id, not a constant.
        guard let workspaceID = try? WorkspaceStore.shared.current().id else {
            AssistAntLog.info("scratch: no workspace — dropping the note")
            return
        }
        // Shared with the `scratch.add` request handler, so a note the agent
        // parks is the same row shape as one typed into the composer — there is
        // one definition of what a note looks like, and it is not in here.
        guard let item = ScratchItem.make(text: text, workspaceID: workspaceID)
        else { return }
        perform { try self.store.create(item) }
    }

    /// Save an inline edit. The title is re-derived so it never describes text
    /// that has since changed.
    func updateBody(id: String, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            try self.store.setTitleAndBody(
                id: id,
                title: ScratchTitle.derive(from: trimmed),
                body: trimmed)
        }
    }

    func resolve(id: String) { perform { try self.store.resolve(id: id) } }
    func unresolve(id: String) { perform { try self.store.unresolve(id: id) } }
    func delete(id: String) { perform { try self.store.softDelete(id: id) } }

    // MARK: - Conversion

    /// Hand notes to the agent to be re-made as actionable items.
    ///
    /// Fire and forget, and deliberately so. This writes nothing to the store,
    /// so there is nothing here to reconcile and nothing to render in flight:
    /// no pending badge, no spinner, no timeout. The agent's `scratch convert`
    /// call comes back through this app's own socket, so `observeScratch`
    /// re-emits and the row leaves the feed on its own. A failure is visible in
    /// the agent transcript, which is where the work is visible anyway.
    ///
    /// The selection is NOT cleared here, unlike `resolveSelected` and friends.
    /// Those land synchronously, so holding their ids would strand the batch bar
    /// over rows already gone; a conversion lands seconds later, and clearing
    /// eagerly would drop the ticks off rows still sitting there — which reads
    /// as the gesture having done nothing. `subscribe`'s `reconcile` drops the
    /// ids at the moment the rows actually leave, which is the honest instant.
    ///
    /// One payload and one slash command for the whole set rather than one per
    /// note: `sendCommand` is immediate and unqueued, so N commands collide in
    /// the input buffer, and it retypes on a lost submit — N gestures' worth of
    /// retries for one gesture. The skill still converts each note with its own
    /// CLI call, so a batch is not a transaction: some notes can land while
    /// others fail.
    func convert(_ items: [Item], to kind: ItemType) {
        guard ItemType.actionableCases.contains(kind) else { return }
        let notes = items.filter { !($0.body ?? "").isEmpty }
        guard !notes.isEmpty else { return }
        // Checked before the write, so a stopped agent doesn't leave a payload
        // file in the runtime dir that nothing will ever read.
        guard AgentSessionController.shared.state == .running else {
            AssistAntLog.info("scratch: convert skipped — the agent isn't running")
            return
        }
        do {
            let path = try Self.writeConversionPayload(notes, kind: kind)
            AgentSessionController.shared.sendCommand(
                "/assist-ant-convert-scratch \(path)")
            AssistAntLog.info(
                "scratch: convert requested — \(notes.count) note(s) → \(kind.rawValue)")
            // Show the agent, because it is the only thing that reports on this.
            // There is no pending state on the row and no timeout by design, so
            // leaving the user on a feed that looks untouched for several seconds
            // invites pressing the chord again — which the in-place conversion
            // survives, but which reads as the gesture having failed. Quick
            // Capture surfaces the session after an Ask for the same reason.
            MainTabNavigator.shared.selectedTab = .terminal
        } catch {
            AssistAntLog.info("scratch: conversion payload write failed — \(error)")
        }
    }

    /// Write the request as a transient `{kind, items:[{id, text}]}` JSON payload
    /// under the runtime dir and return its path for the skill to read. Same
    /// disposable-file idiom as the capture payload, and named
    /// `convert-<uuid>.json` beside its `capture-<uuid>.json` so the prefix says
    /// which skill is meant to pick it up.
    ///
    /// `text` is the note's body, which is the whole note. The stored title is
    /// deliberately left out: it is a derived first-line excerpt that exists to
    /// satisfy a NOT NULL column, and handing it over would invite the agent to
    /// keep it instead of composing a real one.
    private static func writeConversionPayload(
        _ notes: [Item], kind: ItemType
    ) throws -> String {
        let dir = AssistAntPaths.runtimeDir
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "convert-\(UUID().uuidString.lowercased()).json")
        let payload: [String: Any] = [
            "kind": kind.rawValue,
            "items": notes.map { ["id": $0.id, "text": $0.body ?? ""] },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// Run a store mutation, logging rather than throwing.
    ///
    /// The feed is live, so a successful write shows up on its own and there is
    /// nothing to reconcile here. A failure is logged because silence would
    /// read as the keystroke not registering.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            AssistAntLog.info("scratch: store write failed — \(error)")
        }
    }
}
