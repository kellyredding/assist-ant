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
            // reference entries the new feed cannot show.
            selection.clearSelection()
            subscribe()
        }
    }
    @Published private(set) var entries: [Item] = []
    /// The composer's live text. Held across tab switches on purpose.
    @Published var draft: String = ""
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
                // up over rows that are gone.
                let visible = items.map(\.id)
                self.selection.reconcile(
                    visible: visible, present: Set(visible))
            }
    }

    /// The selected entries, in feed order.
    var selectedEntries: [Item] {
        entries.filter { selection.selectedIDs.contains($0.id) }
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
        let now = Date()
        let item = Item(
            id: UUIDv7.generate(),
            workspaceID: workspaceID,
            type: ItemType.scratch.rawValue,
            title: ScratchTitle.derive(from: text),
            body: text,
            source: "manual",
            externalID: nil,
            typeData: .scratch(ScratchData()),
            iceboxedAt: nil,
            deletedAt: nil,
            scheduledOn: nil,
            resolvedAt: nil,
            position: nil,
            createdAt: now,
            updatedAt: now,
            serverUpdatedAt: nil,
            pending: false
        )
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
