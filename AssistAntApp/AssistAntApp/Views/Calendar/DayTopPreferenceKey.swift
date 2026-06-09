import SwiftUI

/// Collects each day header's top offset (in the agenda coordinate space) so
/// the pane can pick the topmost-visible day for the month label and the
/// chevron anchor. Merged across all realized sections each layout pass.
struct DayTopPreferenceKey: PreferenceKey {
    static var defaultValue: [CivilDate: CGFloat] = [:]
    static func reduce(
        value: inout [CivilDate: CGFloat], nextValue: () -> [CivilDate: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
