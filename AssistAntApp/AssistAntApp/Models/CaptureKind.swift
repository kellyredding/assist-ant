import Foundation

/// The kinds the Quick Capture popover offers. `ask` is freeform direction sent
/// to the live agent; `todo` / `reminder` / `explore` become inbox items; `task`
/// is a task-creation request handed to the agent, which infers any schedule and
/// authors the task. Glyphs match the design (SF Symbols).
enum CaptureKind: String, CaseIterable, Identifiable {
    case ask
    case todo
    case reminder
    case explore
    case task

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask"
        case .todo: return "To-do"
        case .reminder: return "Reminder"
        case .explore: return "Explore"
        case .task: return "Task"
        }
    }

    var sfSymbol: String {
        switch self {
        case .ask: return "bubble.left"
        case .todo: return "checklist"
        case .reminder: return "pin"
        case .explore: return "bookmark"
        case .task: return "calendar.badge.clock"
        }
    }
}
