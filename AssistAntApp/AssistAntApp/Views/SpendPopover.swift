import SwiftUI
import AppKit

/// The spend popover: each captured variant as a card placed side-by-side, body
/// rendered verbatim in a monospaced font (the raw /spend block — sparkline + bar
/// graph). Each card grows to its content height, bounded by the main window's
/// usable height (tracked live, so shrinking the window while the popover is open
/// shrinks the cards); content taller than the bound scrolls. The app renders; it
/// does not parse.
struct SpendPopoverContent: View {
    let state: SpendState?
    @StateObject private var layout = SpendPopoverHeight()

    var body: some View {
        Group {
            if let state, !state.variants.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(state.variants, id: \.label) {
                        SpendVariantCard(variant: $0, maxBodyHeight: layout.cap)
                    }
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No spend captured yet")
                        .font(.headline)
                    Text("Enable the “Spend capture” task in the Tasks tab — it "
                        + "records your spend every couple of hours — or run it "
                        + "now to populate this.")
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

/// Tracks the usable height of the main window (its content area, below the title
/// bar) and republishes it on resize, so the popover can bound its cards to "the
/// bottom of the window" and follow a live resize while it's open.
@MainActor
final class SpendPopoverHeight: ObservableObject {
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
        // Leave room for the card header + the popover's own padding and arrow.
        cap = max(160, usable - 96)
    }
}

/// Reports the natural height of a card's body so the ScrollView can size to its
/// content (up to the window-derived cap) instead of always filling the cap.
private struct CardBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SpendVariantCard: View {
    let variant: SpendState.Variant
    let maxBodyHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(variant.label).font(.headline)
            ScrollView(.vertical) {
                Text(variant.body)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: CardBodyHeightKey.self, value: g.size.height)
                        })
            }
            // Size to content, capped at the window-derived height; taller scrolls.
            .frame(height: min(max(contentHeight, 1), maxBodyHeight))
            .onPreferenceChange(CardBodyHeightKey.self) { contentHeight = $0 }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor)))
    }
}
