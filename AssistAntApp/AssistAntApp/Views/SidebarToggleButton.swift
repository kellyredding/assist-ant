import SwiftUI

/// Titlebar control that toggles the sidebar between its quarter and half
/// widths. Uses the same glyph as Galaxy's sidebar toggle. Clicking snaps to
/// whichever extreme is farther from the current width (see
/// `SidebarLayoutModel.toggle()`), animated.
struct SidebarToggleButton: View {
    @ObservedObject private var layout = SidebarLayoutModel.shared

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                layout.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle sidebar width")
    }
}
