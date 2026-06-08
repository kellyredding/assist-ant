import SwiftUI

/// Root content of the main AssistAnt window. A resizable, non-collapsible
/// left sidebar hosts the clock; the right pane hosts the agent (currently a
/// placeholder). The split is a plain `HStack` with a hand-rolled AppKit drag
/// handle rather than a split-view class — the same approach Galaxy uses
/// (~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/ContentView.swift).
///
/// The sidebar width is a *fraction* of the window width (0.25–0.50), held in
/// `SidebarLayoutModel`. Because it's a ratio, both panes always keep a
/// proportional share at any window size — so there's no minimum-width math
/// and no starvation case. Dragging the divider adjusts the fraction within
/// the band; the titlebar toggle snaps it to the far extreme. The clock
/// scales its fonts to fit the resulting width (see ClockView / ClockMetrics).
struct ContentView: View {
    @ObservedObject private var layout = SidebarLayoutModel.shared

    /// Live width (pixels) while a resize drag is in flight; nil otherwise, at
    /// which point the width is derived from the persisted fraction × the
    /// current window width.
    @State private var draggingWidth: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let windowWidth = geo.size.width
            let minWidth = windowWidth * SidebarMetrics.minFraction
            let maxWidth = windowWidth * SidebarMetrics.maxFraction
            let sidebarWidth = draggingWidth ?? (windowWidth * layout.fraction)

            HStack(spacing: 0) {
                sidebarColumn(width: sidebarWidth)
                resizeHandle(
                    currentWidth: sidebarWidth,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    windowWidth: windowWidth
                )
                agentPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar Column

    /// The today sidebar: the clock in a top band (scaling its fonts to the
    /// sidebar width — see ClockView / ClockMetrics), a divider, then today's
    /// items filling the rest of the column.
    private func sidebarColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ClockView()
            Divider()
            TodayItemsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipped()
        .transaction { t in
            // Suppress implicit animation during the resize drag so the
            // column tracks the cursor 1:1 instead of easing behind it.
            if draggingWidth != nil {
                t.animation = nil
            }
        }
    }

    // MARK: - Agent Pane (placeholder)

    private var agentPane: some View {
        AgentPaneView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Resize Handle

    /// A 1pt separator line overlaid with a wider invisible AppKit drag
    /// target. `minWidth`/`maxWidth` are the live window-relative 25% / 50%
    /// bounds; on drag-end the final width is converted back to a fraction
    /// and persisted so the ratio survives later window resizes.
    private func resizeHandle(
        currentWidth: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .overlay {
                SidebarResizeHandle(
                    currentWidth: currentWidth,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    onWidthChange: { newWidth in
                        draggingWidth = newWidth
                    },
                    onDragEnd: { finalWidth in
                        draggingWidth = nil
                        guard windowWidth > 0 else { return }
                        layout.setFraction(finalWidth / windowWidth)
                    }
                )
                .frame(width: 9)
            }
            .zIndex(100)
    }
}
