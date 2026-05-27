import Foundation
import AppKit
import Combine

/// Singleton that publishes the current time, ticking aligned to wall-clock
/// minute boundaries. UI views observe `currentTime` and re-render whenever
/// a new minute starts.
///
/// One-shot Timer per tick: each fire computes the next :00 boundary and
/// schedules another Timer for that exact instant. Tolerance of 0.5s saves
/// battery without visibly drifting the display. Subscribes to
/// NSWorkspace.didWakeNotification so that a missed tick during sleep is
/// caught up immediately on wake.
final class ClockService: ObservableObject {
    static let shared = ClockService()

    @Published private(set) var currentTime: Date = Date()

    private var timer: Timer?
    private var wakeObserver: AnyCancellable?

    private init() {
        scheduleNextTick()

        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.realign()
            }
    }

    private func scheduleNextTick() {
        timer?.invalidate()

        let now = Date()
        let calendar = Calendar.current
        // Next :00 — Calendar.nextDate gives the earliest future Date where
        // second == 0, which is the next minute boundary.
        guard let next = calendar.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        let delay = next.timeIntervalSince(now)

        timer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.5
    }

    private func tick() {
        currentTime = Date()
        scheduleNextTick()
    }

    /// Force an immediate update and reschedule. Called on wake so the
    /// clock doesn't show a stale time for up to a minute after the Mac
    /// resumes from sleep.
    private func realign() {
        tick()
    }
}
