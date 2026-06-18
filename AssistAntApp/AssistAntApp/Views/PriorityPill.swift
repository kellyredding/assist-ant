import SwiftUI
import Combine

/// Title-bar pill showing how fresh the captured priority snapshot is
/// ("⚑ Priority · 2h ago"). Hidden unless `priority_show` is on; shows an empty
/// state when on but uncaptured, and an amber ⚠ when the latest capture is older
/// than the configured stale window. Click opens the single-block popover.
/// Renders only what the agent stored — no parsing. Mirrors SpendPill, with a
/// static label + relative capture time instead of two data strings.
struct PriorityPill: View {
    @StateObject private var model = PriorityPillModel()

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
                PriorityPopoverContent(state: model.state)
            }
        } else {
            EmptyView()
        }
    }

    /// The pill's interior: the static label + the relative capture time (with a
    /// stale ⚠) once a snapshot exists, otherwise a dimmed placeholder that still
    /// reads as the priority widget and invites a click for setup guidance.
    @ViewBuilder private var pillContent: some View {
        if model.hasCapture {
            HStack(spacing: 4) {
                Image(systemName: model.isStale
                    ? "exclamationmark.triangle.fill" : "flag.fill")
                    .imageScale(.small)
                Text(model.pillText).lineLimit(1)
            }
            .foregroundStyle(model.isStale ? Color.orange : Color.primary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "flag").imageScale(.medium)
                Text("No priorities yet")
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Seeds synchronously from the workspace record, tracks live changes, and
/// re-evaluates freshness each minute off the shared clock (so the relative
/// time and the stale flag advance without a write).
@MainActor
final class PriorityPillModel: ObservableObject {
    @Published var state: PriorityState?
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
        // Re-tick so the relative time advances and a snapshot crosses the stale
        // threshold without a write.
        ClockService.shared.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.now = t }
            .store(in: &bag)
    }

    private func apply(_ ws: Workspace?) {
        isVisible = ws?.priorityShow ?? false
        staleHours = ws?.priorityStaleHours ?? 24
        state = ws?.priorityState
    }

    /// "Priority · 2h ago" — the static label plus the relative capture time.
    var pillText: String {
        guard let captured = state?.capturedAt else { return "Priority" }
        let rel = Self.relative.localizedString(for: captured, relativeTo: now)
        return "Priority · \(rel)"
    }

    /// True once any priority snapshot with a non-blank body has been captured.
    var hasCapture: Bool {
        guard let s = state else { return false }
        return !s.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tooltip text, tailored to the empty / stale / normal state.
    var helpText: String {
        if !hasCapture {
            return "Priority — no capture yet. Enable the “Priority capture” task to populate this."
        }
        return isStale
            ? "Priority — last capture is stale"
            : "Priority — click for details"
    }

    var isStale: Bool {
        guard staleHours > 0, let captured = state?.capturedAt else { return false }
        return now.timeIntervalSince(captured) > Double(staleHours) * 3600
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
