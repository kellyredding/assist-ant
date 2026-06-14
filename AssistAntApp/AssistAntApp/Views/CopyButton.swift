import SwiftUI
import AppKit
import Combine

/// A reusable copy-to-clipboard button that shows a doc.on.doc icon, animates
/// to a green checkmark on success, and reverts after 2 seconds. Ported from
/// Galaxy's CopyButton (its `.chromeFont` is Galaxy-specific, so this uses a
/// plain system font of `iconSize`; behavior — green check, animation, delay —
/// is identical).
///
/// It also flashes the same green check on `.itemsCopiedToClipboard`, posted by
/// the `a c` keyboard chord — so a chord copy gets the same confirmation as a
/// click even though it doesn't touch this button. (When the chord fires the
/// batch control bar is the visible copy glyph; un-hovered row clusters aren't
/// mounted, so they don't flash.)
struct CopyButton: View {
    let text: String
    var iconSize: CGFloat = 13

    @State private var showCopied = false

    var body: some View {
        Button(action: copyText) {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: iconSize))
                .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy for agent")
        .onReceive(NotificationCenter.default.publisher(for: .itemsCopiedToClipboard)) { _ in
            flashCopied()
        }
    }

    private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flashCopied()
    }

    /// Flip to the green checkmark, then revert after 2 seconds — shared by a
    /// click and by the chord broadcast.
    private func flashCopied() {
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showCopied = false }
        }
    }
}
