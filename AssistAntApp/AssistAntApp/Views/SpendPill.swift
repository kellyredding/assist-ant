import SwiftUI
import Combine

/// Title-bar pill showing two agent-composed spend strings ("$392 today ·
/// $2.7k mo"). Hidden unless `spend_show` is on; shows an empty state when on
/// but uncaptured, and an amber ⚠ when the latest capture is older than the
/// configured stale window. Click opens the variant-cards popover. Renders only
/// what the agent stored — no parsing, no formatting. Mirrors WorkspacePill.
struct SpendPill: View {
    @StateObject private var model = SpendPillModel()

    var body: some View {
        if model.isVisible {
            Button { model.showPopover.toggle() } label: {
                pillContent
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .contentShape(Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help(model.helpText)
            .popover(isPresented: $model.showPopover, arrowEdge: .bottom) {
                SpendPopoverContent(state: model.state)
            }
        } else {
            EmptyView()
        }
    }

    /// The pill's interior: the captured strings (with a stale ⚠) once data
    /// exists, otherwise a dimmed placeholder that still reads as the spend
    /// widget and invites a click for setup guidance.
    @ViewBuilder private var pillContent: some View {
        if model.hasCapture {
            HStack(spacing: 4) {
                if model.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                }
                if model.pillText.isEmpty {
                    Image(systemName: "dollarsign").imageScale(.medium)
                } else {
                    Text(model.pillText).lineLimit(1)
                }
            }
            .foregroundStyle(model.isStale ? Color.orange : Color.primary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign").imageScale(.medium)
                Text("No spend data")
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Seeds synchronously from the workspace record, tracks live changes, and
/// re-evaluates staleness each minute off the shared clock.
@MainActor
final class SpendPillModel: ObservableObject {
    @Published var state: SpendState?
    @Published var isVisible: Bool = false
    @Published var staleHours: Int = 24
    @Published var showPopover = false
    @Published private var now = Date()
    private var bag = Set<AnyCancellable>()

    init() {
        apply(try? WorkspaceStore.shared.current())
        WorkspaceStore.shared.observe()
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &bag)
        // Re-tick so a snapshot crosses the stale threshold without a write.
        ClockService.shared.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.now = t }
            .store(in: &bag)
    }

    private func apply(_ ws: Workspace?) {
        isVisible = ws?.spendShow ?? false
        staleHours = ws?.spendStaleHours ?? 24
        state = ws?.spendState
    }

    /// The two captured pill strings joined for display (may be empty if the
    /// agent sent only variant cards). Shown only once `hasCapture` is true.
    var pillText: String {
        guard let s = state else { return "" }
        let parts = [s.primary, s.secondary].compactMap {
            ($0?.isEmpty == false) ? $0 : nil
        }
        return parts.joined(separator: " · ")
    }

    /// True once any spend has been captured (pill strings or variant cards).
    var hasCapture: Bool {
        guard let s = state else { return false }
        return (s.primary?.isEmpty == false)
            || (s.secondary?.isEmpty == false)
            || !s.variants.isEmpty
    }

    /// Tooltip text, tailored to the empty / stale / normal state.
    var helpText: String {
        if !hasCapture {
            return "Spend — no capture yet. Enable the “Spend capture” task to populate this."
        }
        return isStale
            ? "Spend — last capture is stale"
            : "Spend — click for details"
    }

    var isStale: Bool {
        guard staleHours > 0, let captured = state?.capturedAt else { return false }
        return now.timeIntervalSince(captured) > Double(staleHours) * 3600
    }
}
