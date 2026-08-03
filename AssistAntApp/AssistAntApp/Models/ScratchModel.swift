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
            // the first match and drops selections that filtered out.
            let visible = rows.map(\.id)
            selection.reconcile(visible: visible, present: Set(visible))
        }
    }
    /// Selection + keyboard focus, for the batch actions that arrive with the
    /// chords. Present now so the row views can read it from the start.
    let selection = ActionableSelection()

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
                let visible = self.visibleIDs
                self.selection.reconcile(
                    visible: visible, present: Set(visible))
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

    /// Visible ids in display order — what `j`/`k` step through and `*a` selects.
    var visibleIDs: [String] { rows.map(\.id) }

    /// The selected entries, in feed order. Scoped to what is visible so a batch
    /// action can never touch a row the query has hidden.
    var selectedEntries: [Item] {
        rows.map(\.item).filter { selection.selectedIDs.contains($0.id) }
    }

    /// The row `j`/`k` focus currently sits on, if any.
    var focusedEntry: Item? {
        guard let id = selection.focusedItemID else { return nil }
        return rows.first { $0.id == id }?.item
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
