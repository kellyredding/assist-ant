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
    @FocusState private var composerFocused: Bool

    /// One line of the composer's 14pt font plus its text-container insets. The
    /// field starts here and grows with its content rather than reserving room
    /// for a note that has not been typed yet.
    private static let composerLineHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            actionBar
            Divider()
            feed
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusIfSelected() }
        // Selecting the tab focuses the composer. Watching the navigator rather
        // than relying on onAppear alone: every pane stays mounted, so onAppear
        // fires once at launch and never again on a tab switch.
        .onChange(of: tabs.selectedTab) { _, _ in focusIfSelected() }
    }

    private func focusIfSelected() {
        guard tabs.selectedTab == .scratch else { return }
        // A turn later: the field has to exist and be hit-testable before it can
        // take focus, and on a tab switch this runs while the pane is still
        // transparent.
        DispatchQueue.main.async { composerFocused = true }
    }

    // MARK: - Composer

    /// `fixedSize` vertically is what keeps this one line tall. The editor
    /// reports a clamped intrinsic height, but a representable in a flexible
    /// stack otherwise accepts whatever height it is offered — which is how it
    /// came to swallow the pane.
    private var composer: some View {
        GrowingTextEditor(
            text: $model.draft,
            placeholder: "Paste or type a note…",
            minHeight: Self.composerLineHeight,
            maxHeight: 260,
            onSend: { model.submitDraft() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .focused($composerFocused)
        .padding(.leading, ScratchMetrics.composerLeading)
        .padding(.trailing, ScratchMetrics.inset)
        .padding(.vertical, 8)
        // The submit keystroke comes from the text-entry settings, so it tracks
        // whatever the user configured rather than hardcoding one.
        .onTextEntryKeystrokes { model.submitDraft() }
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

            if selection.hasSelection {
                batchToolbar
            }

            Spacer()

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

    private var batchToolbar: some View {
        HStack(spacing: 6) {
            Text("\(selection.selectedIDs.count) selected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            CopyButton(text: ItemClipboard.serialize(model.selectedEntries))
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
            PointerIconButton(systemName: "xmark", help: "Clear selection") {
                selection.clearSelection()
            }
        }
    }

    private var countLabel: String {
        let n = model.entries.count
        return n == 1 ? "1 entry" : "\(n) entries"
    }

    // MARK: - Feed

    @ViewBuilder
    private var feed: some View {
        if model.entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries, id: \.id) { entry in
                        ScratchRow(entry: entry, model: model)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
