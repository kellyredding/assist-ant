import SwiftUI

/// Shown when the embedded agent session fails to start. Names the problem,
/// what AssistAnt expected, and how to fix it — plus a Retry.
struct AgentFailureView: View {
    let reason: AgentFailureReason
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)

            Text(reason.title)
                .font(.system(size: 17, weight: .semibold))

            VStack(spacing: 8) {
                Text(reason.expectation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(reason.fixSuggestion)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)

            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(32)
    }
}
