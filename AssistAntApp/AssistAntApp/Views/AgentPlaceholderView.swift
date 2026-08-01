import SwiftUI

/// The calm centred placeholder the session pane shows while no terminal is
/// mounted: the glyph, an optional spinner, and a caption.
///
/// Factored out of `SessionPaneView` so that view is the state machine and
/// nothing else — the same shape Galaxy's session pane has, where every
/// non-running state is its own view.
struct AgentPlaceholderView: View {
    let caption: String
    var showSpinner: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            AgentPlaceholderGlyph()
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The glyph every non-running state leads with. Shared so the placeholder
/// and the stopped state read as one surface rather than two designs that
/// happen to agree today.
struct AgentPlaceholderGlyph: View {
    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tertiary)
    }
}
