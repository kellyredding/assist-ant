import AppKit
import SwiftUI

/// The calendar-item action cluster: copy + open-link only. A deliberately
/// scaled-back parallel to `ItemActions` (like `TrashActions`), since calendar
/// events carry no resolve/icebox/delete lifecycle. Drives a single item — the
/// only calendar surfaces (row hover, reader) are one-item.
struct CalendarActions: View {
    let item: Item

    var body: some View {
        HStack(spacing: 6) {
            CopyButton(text: ItemClipboard.serialize([item]))
            linkButton
        }
    }

    // Open the meeting/join link. Always shown (disabled + dimmed when the event
    // has no URL) so the button position is stable from one event to the next —
    // matching ItemActions.linkButton.
    private var linkButton: some View {
        let urls = ItemLinks.urls(for: [item])
        return PointerIconButton(systemName: "arrow.up.right", help: "Open link") {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
        .disabled(urls.isEmpty)
        .opacity(urls.isEmpty ? 0.4 : 1)
    }
}
