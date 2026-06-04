import SwiftUI

/// Shared source of truth for the sidebar's width as a *fraction* of the
/// window (0.25–0.50). Observed by `ContentView` (for layout) and the
/// titlebar `SidebarToggleButton`. Stored as a fraction so the ratio holds
/// across window resizes and display moves; persisted via
/// `WindowStatePersistence`.
final class SidebarLayoutModel: ObservableObject {
    static let shared = SidebarLayoutModel()

    @Published var fraction: CGFloat

    private init() {
        fraction = WindowStatePersistence.shared.loadSidebarFraction()
    }

    /// Set a new fraction (clamped to the allowed band) and persist it.
    func setFraction(_ newFraction: CGFloat) {
        let clamped = min(
            max(newFraction, SidebarMetrics.minFraction),
            SidebarMetrics.maxFraction
        )
        fraction = clamped
        WindowStatePersistence.shared.saveSidebarFraction(clamped)
    }

    /// Snap to the extreme farther from the current width: if closer to the
    /// minimum (more collapsed), expand to the maximum; otherwise collapse to
    /// the minimum.
    func toggle() {
        let target = fraction < SidebarMetrics.toggleThreshold
            ? SidebarMetrics.maxFraction
            : SidebarMetrics.minFraction
        setFraction(target)
    }
}
