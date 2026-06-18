import SwiftUI
import AppKit

/// The priority popover: the captured snapshot rendered verbatim in a monospaced
/// font (the raw /assist-ant-progress block). The single block grows to its
/// content height, bounded by the main window's usable height (tracked live, so
/// shrinking the window while the popover is open shrinks the block); content
/// taller than the bound scrolls. The app renders; it does not parse. Mirrors
/// SpendPopover, with one block instead of side-by-side variant cards.
struct PriorityPopoverContent: View {
    let state: PriorityState?
    @StateObject private var layout = PriorityPopoverHeight()

    var body: some View {
        Group {
            if let state, !state.body.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty {
                PriorityBlockCard(text: state.body, maxBodyHeight: layout.cap)
                    .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No priorities captured yet")
                        .font(.headline)
                    Text("Enable the “Priority capture” task in the Tasks tab — it "
                        + "reprioritizes your items on a schedule — or run the "
                        + "/assist-ant-progress skill to populate this.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                .padding(16)
            }
        }
    }
}

/// Tracks the usable height of the main window (its content area, below the
/// title bar) and republishes it on resize, so the popover can bound its block
/// to "the bottom of the window" and follow a live resize while it's open.
@MainActor
final class PriorityPopoverHeight: ObservableObject {
    @Published var cap: CGFloat = 360
    private weak var window: NSWindow?
    private var token: NSObjectProtocol?

    init() {
        window = NSApp.windows.first { $0 is AssistAntWindow } ?? NSApp.mainWindow
        recompute()
        if let window {
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private func recompute() {
        let usable = window?.contentLayoutRect.height
            ?? NSScreen.main?.visibleFrame.height ?? 600
        // Leave room for the popover's own padding and arrow.
        cap = max(160, usable - 96)
    }
}

/// Reports the natural height of the block so the ScrollView can size to its
/// content (up to the window-derived cap) instead of always filling the cap.
private struct PriorityBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PriorityBlockCard: View {
    let text: String
    let maxBodyHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: PriorityBodyHeightKey.self, value: g.size.height)
                    })
        }
        // Size to content, capped at the window-derived height; taller scrolls.
        .frame(height: min(max(contentHeight, 1), maxBodyHeight))
        .onPreferenceChange(PriorityBodyHeightKey.self) { contentHeight = $0 }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor)))
    }
}
