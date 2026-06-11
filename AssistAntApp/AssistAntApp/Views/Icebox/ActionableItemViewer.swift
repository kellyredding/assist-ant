import AppKit
import SwiftUI

/// Full-takeover reader for a single actionable item, shown inside the
/// Icebox tab in place of the list. A control-bar header (title + the same
/// item actions a list row exposes + close), a metadata line (kind · list ·
/// iceboxed date · link), then the scrollable markdown body. Mirrors
/// CalendarEventViewer; dismissal lives in IceboxPaneView, which reports
/// close via `onClose`. `onItemChange` carries the post-action item back so
/// the reader reflects a Done / Move / reclassify (and its undo) in place.
struct ActionableItemViewer: View {
    let item: Item
    let onClose: () -> Void
    var onItemChange: (Item) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            metaBar
            EventBodyTextView(markdown: item.body ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    // A control bar: the title on the left, then the same actions a list row
    // exposes on hover, then the close button. The title left-aligns (rather
    // than centering) to make room for the action cluster — this is a working
    // toolbar, not just a label. Dismissed by ✕ or Escape.
    private var header: some View {
        HStack(spacing: 10) {
            Text(item.title)
                .font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            IceboxItemActions(item: item, onChange: onItemChange)
            PointerIconButton(
                systemName: "xmark", help: "Close (Esc)", action: onClose
            )
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    private var metaBar: some View {
        HStack(spacing: 8) {
            KindBadge(item: item)
            if !metaText.isEmpty {
                Text(metaText)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let url = item.actionableExternalURL, let u = URL(string: url) {
                PointerIconButton(
                    systemName: "arrow.up.right.square",
                    help: "Open link in browser",
                    action: { NSWorkspace.shared.open(u) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    /// List name and iceboxed date, joined with a middot — the non-badge meta.
    private var metaText: String {
        var parts: [String] = []
        if let list = item.actionableListName { parts.append(list) }
        if let at = item.iceboxedAt {
            parts.append("Iceboxed \(Self.dateFormatter.string(from: at))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
