import AppKit
import SwiftUI

/// The Icebox tab's content: a control bar over a scrolled, grouped list of
/// iceboxed items. Snapshot model: the list re-fetches on activation + refresh
/// only. Opening a row hands the item to ItemViewerModel, which presents the
/// reader centrally (above the tab content) and owns its edit session and
/// keystroke handling — the reader is no longer hosted here.
///
/// The pane installs a list-level key monitor for Gmail-style navigation and
/// selection (J/K focus, X toggle, Enter opens, `*a` / `*n` select-all / none).
/// It is mutually exclusive with the reader's own monitor: every handler is
/// gated on `ItemViewerModel.openItem == nil` and goes inert while a text field
/// holds focus, so the two monitors never both act on a keystroke.
struct IceboxPaneView: View {
    @ObservedObject private var model = IceboxModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared

    @State private var keyMonitor: Any?
    @State private var pendingStar = false          // saw `*`, awaiting a / n
    @State private var starTimer: DispatchWorkItem?

    var body: some View {
        listPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .onAppear {
                if navigator.selectedTab == .icebox { model.activate() }
                installListKeyMonitor()
            }
            .onChange(of: navigator.selectedTab) { _, tab in
                if tab == .icebox { model.activate() }
            }
            .onDisappear { removeListKeyMonitor() }
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.groups) { group in
                            IceboxGroupSection(
                                group: group,
                                isCollapsed: group.listName.map(model.isCollapsed) ?? false,
                                onToggle: { name in model.toggleCollapse(name) },
                                onOpen: { item in
                                    // Carry keyboard focus to the opened row so
                                    // returning from the reader leaves it focused.
                                    model.focus(item.id)
                                    ItemViewerModel.shared.open(item, over: .icebox)
                                }
                            )
                        }
                    }
                }
                // Keep the keyboard-focused row visible as J/K move it.
                .onChange(of: model.focusedItemID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - List key monitor (mutually exclusive with the reader's)

    private func installListKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only when the Icebox list is the live surface: on its tab, no
            // reader up (the reader owns its own monitor), and not typing in a
            // text field.
            guard navigator.selectedTab == .icebox,
                  ItemViewerModel.shared.openItem == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView)
            else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased()

            // `*` prefix → wait briefly for a / n (Gmail-style sequence).
            if event.characters == "*" {
                pendingStar = true
                starTimer?.cancel()
                let work = DispatchWorkItem { pendingStar = false }
                starTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
                return nil
            }
            if pendingStar {
                pendingStar = false
                starTimer?.cancel()
                if chars == "a" { model.selectAllInFocusedGroup(); return nil }
                if chars == "n" { model.clearSelection(); return nil }
                // any other key cancels the sequence and falls through
            }

            switch chars {
            case "j": model.moveFocus(by: 1); return nil
            case "k": model.moveFocus(by: -1); return nil
            case "x": model.toggleSelectedFocused(); return nil
            default: break
            }
            if event.keyCode == 36 || event.keyCode == 76 {        // Return / Enter
                if let item = model.focusedItem {
                    ItemViewerModel.shared.open(item, over: .icebox)
                    return nil
                }
            }
            return event
        }
    }

    private func removeListKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        starTimer?.cancel()
        pendingStar = false
    }
}
