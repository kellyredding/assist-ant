import AppKit
import SwiftUI

/// The Icebox tab's content: a control bar over a scrolled, grouped list of
/// iceboxed items — or, when an item is open, a full-takeover reader in its
/// place. Snapshot model: the list re-fetches on activation + refresh only.
///
/// This pane is the stable host for the reader's edit session and its
/// keystroke handling: while the reader is open a local key monitor owns just
/// the reader's own commands (⌘↵ save / enter-edit, Esc cancel / close, Tab to
/// swap title⇄body). Tab-switch navigation (⌘←/→, ⌘H/⌘L) is surrendered to the
/// focused editor by disabling the View-menu items while a text field has focus
/// (MenuActions.validateMenuItem), so the text view keeps its full native
/// bindings — including ⌘⇧←/→ selection and ⌥-word motion.
struct IceboxPaneView: View {
    @ObservedObject private var model = IceboxModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared
    @StateObject private var edit = ActionableEditSession()

    @State private var openItem: Item?
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            listPane.disabled(openItem != nil)
            if let item = openItem {
                ActionableItemViewer(
                    item: item,
                    edit: edit,
                    onClose: { closeViewer() },
                    onItemChange: { openItem = $0 },
                    onBeginEdit: { beginEdit() },
                    onCancelEdit: { cancelEdit() },
                    onSave: { saveEdit() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { if navigator.selectedTab == .icebox { model.activate() } }
        .onChange(of: navigator.selectedTab) { _, tab in
            if tab == .icebox { model.activate() }
        }
        .onChange(of: openItem != nil) { _, isOpen in
            if isOpen { installKeyMonitor() } else { removeKeyMonitor() }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            IceboxControlBar(
                onRefresh: { model.refresh() },
                isWorking: model.isWorking
            )
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.groups.isEmpty {
            VStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            VStack {
                Spacer()
                Text("Nothing in the icebox")
                    .font(.callout).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.groups) { group in
                        IceboxGroupSection(
                            group: group,
                            isCollapsed: group.listName.map(model.isCollapsed) ?? false,
                            onToggle: { name in model.toggleCollapse(name) },
                            onOpen: { openItem = $0 }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Edit session

    private func beginEdit() {
        guard let item = openItem else { return }
        edit.begin(title: item.title, body: item.body ?? "")
    }

    private func cancelEdit() { edit.cancel() }

    private func saveEdit() {
        guard let item = openItem, edit.canSave else { return }
        edit.isSaving = true
        let title = edit.title, body = edit.body
        // The store write is synchronous; defer so the spinner paints, then
        // persist, hand the refreshed item back, and drop to the reader.
        Task { @MainActor in
            if let updated = IceboxModel.shared.setTitleAndBody(
                item, title: title, body: body
            ) {
                openItem = updated
            }
            edit.finishSaving()
        }
    }

    private func closeViewer() {
        edit.cancel()
        openItem = nil
    }

    // MARK: - Key monitor

    // While the reader is open, own only the reader's own commands (⌘↵, Esc,
    // Tab). Navigation shortcuts are NOT intercepted here — the View-menu nav
    // items are disabled while a text field is focused, so ⌘←/→, ⌘⇧←/→, and
    // ⌥-arrows reach the editor with their native bindings intact. Everything
    // unmatched falls through to the focused field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard navigator.selectedTab == .icebox, openItem != nil else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let key = event.keyCode

            if key == 53 {                                  // Escape
                // A non-empty text selection swallows the first Escape by
                // collapsing to a caret; only a selection-free Escape exits
                // edit / closes the reader. Applies to the editable fields and
                // the read-only body alike (it's selectable).
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
                   tv.selectedRange().length > 0 {
                    tv.setSelectedRange(NSRange(location: tv.selectedRange().location, length: 0))
                    return nil
                }
                if edit.isEditing {
                    cancelEdit()
                } else {
                    DispatchQueue.main.async { closeViewer() }
                }
                return nil
            }

            if edit.isEditing {
                if cmd && (key == 36 || key == 76) {        // ⌘↵ → save
                    saveEdit()
                    return nil
                }
                if key == 48 {                              // Tab / ⇧Tab → swap field
                    edit.focus = (edit.focus == .title) ? .body : .title
                    return nil
                }
                // ⌘←/→, ⌘⇧←/→, ⌥-arrows, ⌘H/⌘L etc. are NOT touched here. The
                // View-menu nav items are disabled while a text field is focused
                // (MenuActions.validateMenuItem), so these fall through to the
                // editor and get their full native bindings.
                return event
            } else {
                if cmd && (key == 36 || key == 76) {        // ⌘↵ → enter edit
                    beginEdit()
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
