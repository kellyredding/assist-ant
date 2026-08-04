import AppKit
import SwiftUI

/// The ⋮ glyph that pops an AppKit menu — the shared chrome behind every
/// item-level overflow menu (`ItemActions`, `TrashActions`,
/// `ScratchRowMenu`). The caller supplies only the items.
///
/// A real pointer-button (hover highlight + hand cursor, like the copy and link
/// glyphs) rather than a SwiftUI `Menu`. That is not a preference: `pointerButton`
/// installs an AppKit overlay that is the topmost hit view and answers `mouseUp`
/// itself, so a `Menu` underneath it would never see the one click it needs. The
/// click builds an `NSMenu` and pops it instead.
///
/// Extracted when scratch became the third surface to want one — the glyph and
/// the origin-clamping math were already duplicated byte-for-byte between the
/// icebox and trash clusters, which is the kind of copy that drifts silently.
struct ItemMenuButton: View {
    /// Fills the menu. Called on each click rather than once at build time, so
    /// the items always describe the current selection — a batch menu built
    /// eagerly would describe whatever was ticked when the bar last rendered.
    let populate: (NSMenu) -> Void

    @State private var isHovering = false

    var body: some View {
        // Vertical triple-dots: the horizontal `ellipsis` rotated 90° (there is
        // no guaranteed vertical SF Symbol). The overlay is the topmost hit
        // view, so the hand cursor wins over the glyph everywhere.
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 13)).foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .pointerButton(onHoverChange: { isHovering = $0 }, action: present)
    }

    private func present() {
        let menu = NSMenu()
        // Callers manage `isEnabled` explicitly (ItemActions greys a synced
        // Delete), and AppKit's auto-validation would re-enable it. Off for
        // everyone rather than per-caller: a menu that silently re-enables an
        // item you disabled is a footgun with no upside.
        menu.autoenablesItems = false
        populate(menu)

        // Match the window's light/dark appearance — a detached NSMenu otherwise
        // defaults to the system appearance — and clamp the origin so the whole
        // menu stays inside the window instead of spilling past its edge.
        // `in: nil` → `at` is the menu's top-left in screen coordinates (the
        // menu extends down and right from there).
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        menu.appearance = window?.effectiveAppearance
        var origin = NSEvent.mouseLocation
        if let frame = window?.frame {
            let size = menu.size
            origin.x = max(frame.minX, min(origin.x, frame.maxX - size.width))
            origin.y = min(frame.maxY, max(origin.y, frame.minY + size.height))
        }
        menu.popUp(positioning: nil, at: origin, in: nil)
    }
}
