import AppKit
import SwiftUI

/// Compact find bar shown above a searchable WKWebView. The
/// controller's `webView` determines what is actually being
/// searched. Hides itself by binding to `controller.isVisible`;
/// surrounding chrome decides when to flip that flag.
///
/// Uses an AppKit-backed `FindTextFieldRepresentable` instead of
/// SwiftUI's `TextField` to avoid the latter's heavier cold-init
/// cost. The bar itself is hosted in a separate `NSPanel` (see
/// `FindBarPanel`) so AppKit's password-autofill heuristic walks
/// the panel's tiny view tree on first-responder transitions
/// instead of the parent window's full SwiftUI hierarchy.
struct FindBarView: View {
    @ObservedObject var controller: WebViewFindController

    /// Fixed sizes where Galaxy scales these through a chrome-font
    /// setting. AssistAnt has no such setting, so these are its
    /// values at scale 1.0.
    private static let iconFont = Font.system(size: 12)
    private static let matchFont = Font.system(
        size: 11, design: .monospaced
    )
    private static let fieldFont = NSFont.monospacedSystemFont(
        ofSize: 10, weight: .regular
    )

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Self.iconFont)
                .foregroundColor(.secondary)

            FindTextFieldRepresentable(
                text: $controller.query,
                placeholder: "Find",
                font: Self.fieldFont,
                textColor: .labelColor,
                onSubmit: { controller.next() },
                onShiftSubmit: { controller.prev() },
                onCancel: { controller.isVisible = false }
            )
            .frame(minWidth: 160)

            Text(matchLabel)
                .font(Self.matchFont)
                .foregroundColor(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            // Up arrow always walks visually UP. In forward
            // mode (artifact / snapshot readers) that maps to
            // controller.prev(); in reverse mode (scrollback,
            // where the JS pipeline iterates from the most
            // recent match back through history) it maps to
            // controller.next(). Icon position stays fixed —
            // up on the left, down on the right — to match
            // every other macOS find UI.
            Button(action: walkUpAction) {
                Image(systemName: "chevron.up")
                    .font(Self.iconFont)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            // ⇧↩ is also handled inside the text field's
            // doCommandBy: when focus is in the field. This
            // shortcut covers the case where focus has drifted
            // elsewhere (e.g., after a click outside).
            .keyboardShortcut(.return, modifiers: .shift)
            .help(walkUpHelp)

            Button(action: walkDownAction) {
                Image(systemName: "chevron.down")
                    .font(Self.iconFont)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help(walkDownHelp)

            Button(action: { controller.isVisible = false }) {
                Image(systemName: "xmark")
                    .font(Self.iconFont)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Tertiary fallback for Esc — text field handles it
            // first via cancelOperation:, AppKit-level Esc
            // monitors in the parent views (scrollback overlay,
            // artifact reader) handle it as belt-and-suspenders.
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(radius: 4, y: 2)
        )
    }

    private var matchLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return "No matches" }
        return "\(controller.matchIndex + 1) "
            + "of \(controller.matchCount)"
    }

    /// Action for the up-arrow button. The button always walks
    /// visually UP; which controller method that corresponds to
    /// depends on whether the surface iterates forward or
    /// reverse. The JS pipeline's reverseMode flips next/prev's
    /// step direction, so calling next in a reverse-mode
    /// controller actually walks UP.
    private func walkUpAction() {
        if controller.reverse {
            controller.next()
        } else {
            controller.prev()
        }
    }

    /// Action for the down-arrow button — symmetric to walkUp.
    private func walkDownAction() {
        if controller.reverse {
            controller.prev()
        } else {
            controller.next()
        }
    }

    /// Tooltip on the up-arrow button. The shortcut hint
    /// reflects which keyboard chord triggers the same motion
    /// from the field: in forward mode walking up is the
    /// secondary action (Shift+Return), in reverse mode it's
    /// the primary action (Return).
    private var walkUpHelp: String {
        controller.reverse
            ? "Next match (↩)"
            : "Previous match (⇧↩)"
    }

    /// Tooltip on the down-arrow button — symmetric to walkUp.
    private var walkDownHelp: String {
        controller.reverse
            ? "Previous match (⇧↩)"
            : "Next match (↩)"
    }
}
