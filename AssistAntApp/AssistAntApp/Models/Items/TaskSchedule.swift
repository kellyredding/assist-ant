import Foundation

/// Pure due-evaluator for the heartbeat: given a scheduled task and the current
/// instant, decide whether it should fire *now*. No AppKit, no timers, no I/O —
/// lives in `Models/Items/` so the smoke tool exercises every cadence path.
///
/// Only `recurring` and `one_shot` are evaluated; `manual` and `today` are
/// user/glyph-triggered and always return `false`. The caller
/// (`HeartbeatService`) pre-filters to *enabled* tasks, so enablement isn't
/// re-checked here.
///
/// Coalescing ("never replay missed intervals") is emergent: anchored cadences
/// (daily, windowed interval) fire once for the most-recent scheduled slot ≤
/// now; the free-running interval fires once per elapsed interval. A long
/// sleep/quit yields a single catch-up fire, not one per missed slot.
enum TaskSchedule {
    static func isDue(_ task: AgentTask, now: Date, calendar: Calendar = .current) -> Bool {
        switch task.triggerType {
        case "one_shot":  return oneShotDue(task, now: now)
        case "recurring": return recurringDue(task, now: now, calendar: calendar)
        default:          return false   // manual / today never fire on a tick
        }
    }

    // MARK: - one_shot

    private static func oneShotDue(_ task: AgentTask, now: Date) -> Bool {
        guard let runAt = task.runAt else { return true }   // nil = fire next tick
        return now >= runAt
    }

    // MARK: - recurring

    private static func recurringDue(_ task: AgentTask, now: Date, calendar: Calendar) -> Bool {
        switch task.cadenceKind {
        case "daily":    return dailyDue(task, now: now, calendar: calendar)
        case "interval": return intervalDue(task, now: now, calendar: calendar)
        default:         return false
        }
    }

    private static func dailyDue(_ task: AgentTask, now: Date, calendar: Calendar) -> Bool {
        guard let time = task.dailyTime,
              let slot = mostRecentSlot(time: time, onOrBefore: now, calendar: calendar)
        else { return false }
        guard task.weekdaySet.contains(isoWeekday(of: slot, calendar)) else { return false }
        if let last = task.lastRunAt { return last < slot }
        return slot >= task.createdAt   // first fire only for a post-creation slot
    }

    private static func intervalDue(_ task: AgentTask, now: Date, calendar: Calendar) -> Bool {
        guard let interval = task.intervalSeconds, interval > 0 else { return false }

        // Windowed interval: only inside [open, close] on an allowed weekday, at
        // the most-recent anchored slot (open + k·interval ≤ now).
        if let ws = task.windowStart, let we = task.windowEnd {
            guard task.weekdaySet.contains(isoWeekday(of: now, calendar)),
                  let open = slot(time: ws, sameDayAs: now, calendar: calendar),
                  let close = slot(time: we, sameDayAs: now, calendar: calendar),
                  now >= open, now <= close
            else { return false }
            let k = floor(now.timeIntervalSince(open) / Double(interval))
            let fireSlot = open.addingTimeInterval(k * Double(interval))
            if let last = task.lastRunAt { return last < fireSlot }
            return fireSlot >= task.createdAt
        }

        // Continuous interval: free-running; anchor the first fire to createdAt.
        guard task.weekdaySet.contains(isoWeekday(of: now, calendar)) else { return false }
        let anchor = task.lastRunAt ?? task.createdAt
        return now.timeIntervalSince(anchor) >= Double(interval)
    }

    // MARK: - helpers

    /// ISO weekday (1=Mon … 7=Sun). `Calendar.weekday` is 1=Sun … 7=Sat, so remap.
    static func isoWeekday(of date: Date, _ calendar: Calendar) -> Int {
        let w = calendar.component(.weekday, from: date)
        return w == 1 ? 7 : w - 1
    }

    /// The "HH:MM" slot on the same calendar day as `ref` (nil if unparseable).
    static func slot(time: String, sameDayAs ref: Date, calendar: Calendar) -> Date? {
        let p = time.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return calendar.date(bySettingHour: p[0], minute: p[1], second: 0, of: ref)
    }

    /// The latest occurrence of an "HH:MM" daily slot at or before `now` —
    /// today's if `now` is past it, else yesterday's.
    static func mostRecentSlot(time: String, onOrBefore now: Date, calendar: Calendar) -> Date? {
        guard let todays = slot(time: time, sameDayAs: now, calendar: calendar) else { return nil }
        if todays <= now { return todays }
        return calendar.date(byAdding: .day, value: -1, to: todays)
    }
}
