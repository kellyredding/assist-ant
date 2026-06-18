import Foundation

/// The captured priority display state — one agent-composed monospaced summary
/// block, stored as JSON on the workspace record. The app is a pure renderer:
/// `body` is the verbatim prioritized progress snapshot (from the
/// `/assist-ant-progress` skill) shown in the popover, and `capturedAt` drives
/// both the "as of <time>" chip and the stale indicator. Nothing here is parsed
/// app-side. Mirrors SpendState, minus the pill strings and multi-card variants.
struct PriorityState: Codable, Equatable {
    var body: String        // the raw progress block, verbatim
    var capturedAt: Date
}
