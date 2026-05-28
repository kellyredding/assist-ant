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
///
/// Run loop mode: the Timer is added to `.common`, NOT `.default`. The
/// difference matters because `Timer.scheduledTimer(...)` (the
/// convenience form) only adds to `.default`, which means the timer
/// stalls whenever the run loop is in `.modalPanel` (Settings modal),
/// `.eventTracking` (scroll/drag), or `.tracking` (menu open). `.common`
/// is a meta-mode that fires in all of those plus idle — keeping the
/// clock and announcements alive through any UI mode.
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

        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.5
        // Explicit add to `.common` rather than `.scheduledTimer` (which
        // adds to `.default` only) — see type doc for the run-loop-mode
        // rationale.
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
