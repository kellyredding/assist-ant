import AppKit
import SwiftUI

/// The Icebox tab's content: a control bar over a scrolled, grouped list of
/// iceboxed items — or, when an item is open, a full-takeover reader in its
/// place. Snapshot model: the list re-fetches on activation + refresh only.
struct IceboxPaneView: View {
    @ObservedObject private var model = IceboxModel.shared
    @ObservedObject private var navigator = MainTabNavigator.shared

    @State private var openItem: Item?
    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            listPane.disabled(openItem != nil)
            if let item = openItem {
                ActionableItemViewer(
                    item: item,
                    onClose: { openItem = nil },
                    onItemChange: { openItem = $0 }
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
            if isOpen { installEscapeMonitor() } else { removeEscapeMonitor() }
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

    // MARK: - Escape monitor (mirrors SchedulePaneView)

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }     // Escape
            guard navigator.selectedTab == .icebox else { return event }
            DispatchQueue.main.async { openItem = nil }
            removeEscapeMonitor()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
