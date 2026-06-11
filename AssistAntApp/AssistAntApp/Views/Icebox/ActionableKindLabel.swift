import Foundation

/// UI strings for an actionable item's kind. Presentation only — the code
/// layer keeps the "actionable" vocabulary; these are what the user sees.
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

    /// Resolve-button verb: "Done" for to-do and explore, "Dismiss" for
    /// reminder.
    static func resolveVerb(for item: Item) -> String {
        if case .reminder = item.typeData { return "Dismiss" }
        return "Done"
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
}
