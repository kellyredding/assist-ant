import Foundation

/// Which posture the user is currently in at the desk. Tracked by
/// assumption + acknowledgment (AssistAnt never reads the desk
/// hardware).
enum DeskPosition: String, Codable, Equatable {
    case sitting
    case standing

    var opposite: DeskPosition {
        self == .sitting ? .standing : .sitting
    }

    var displayName: String {
        switch self {
        case .sitting:  return "Sitting"
        case .standing: return "Standing"
        }
    }

    /// Imperative verb for prompting a switch *to* this position:
    /// "stand" / "sit". So a nudge out of sitting reads
    /// "Time to \(DeskPosition.standing.verb)" → "Time to stand".
    var verb: String {
        switch self {
        case .sitting:  return "sit"
        case .standing: return "stand"
        }
    }
}
