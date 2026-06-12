import SwiftUI

/// UI strings + styling for an actionable item's kind. Presentation only —
/// the code layer keeps the "actionable" vocabulary; these are what the user
/// sees.
enum ActionableKindLabel {
    /// Kind badge text, or nil for a non-actionable item.
    static func badge(for item: Item) -> String? {
        switch item.typeData {
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        default: return nil
        }
    }

    /// Resolve-button verb for one item — delegates to the model-layer
    /// `ItemActionState` so the single source of truth also covers batches.
    static func resolveVerb(for item: Item) -> String {
        ItemActionState.verb(for: [item])
    }

    /// Menu title for a kind offered by the reclassify menu.
    static func menuTitle(_ kind: ItemType) -> String {
        switch kind {
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        case .calendar: return ""   // never offered
        }
    }

    /// Badge background color (always paired with white text), or nil for a
    /// non-actionable item.
    static func color(for item: Item) -> Color? {
        switch item.typeData {
        // One deep navy for both themes: dark enough to stay clearly distinct
        // from Explore's brighter royal blue, light enough to hold contrast
        // against the dark-mode window.
        case .todo: return Color(red: 0.16, green: 0.21, blue: 0.55)     // navy
        case .explore: return Color(red: 0.25, green: 0.41, blue: 0.88)  // royal blue
        case .reminder: return Color(red: 0.13, green: 0.48, blue: 0.24) // royal green
        default: return nil
        }
    }
}

/// The colored kind pill (white text) shown in the icebox list and the item
/// reader header. Renders nothing for a non-actionable item.
struct KindBadge: View {
    let item: Item

    var body: some View {
        if let text = ActionableKindLabel.badge(for: item),
           let bg = ActionableKindLabel.color(for: item) {
            Text(text)
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(bg))
                // Faint, theme-aware edge: Color.primary resolves dark in
                // light mode and light in dark mode, so the pill keeps a
                // subtle outline against either background.
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                )
        }
    }
}
