import Foundation

/// The kinds the Quick Capture popover offers. `ask` is freeform direction sent
/// to the live agent; `todo` / `reminder` / `explore` become inbox items in a
/// later phase. Glyphs match the design (SF Symbols).
enum CaptureKind: String, CaseIterable, Identifiable {
    case ask
    case todo
    case reminder
    case explore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        }
    }

    var sfSymbol: String {
        switch self {
        case .ask: return "bubble.left"
        case .todo: return "checklist"
        case .reminder: return "pin"
        case .explore: return "bookmark"
        }
    }
}
