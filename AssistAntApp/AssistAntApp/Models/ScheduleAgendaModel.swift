import Foundation
import Combine

/// Drives the Schedule tab's agenda. Owns the loaded window and navigation.
/// Forward data is fully loaded ([windowStart → ∞)); the past edge
/// (`windowStart`) starts at today and extends a Monday-anchored week at a
/// time via the back chevron. State persists across tab switches (singleton +
/// the tab view stays mounted); only the first activation jumps to today.
@MainActor
final class ScheduleAgendaModel: ObservableObject {
    static let shared = ScheduleAgendaModel()

    /// Rendered day sections (windowStart … last forward event day).
    @Published private(set) var days: [AgendaDay] = []
    /// First-load spinner. Back-load / refresh use `isWorking` so the existing
    /// content stays on screen.
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    /// A day the view should scroll to (anchor .top), consumed once.
    @Published var scrollTarget: CivilDate?
    /// Topmost visible day, written by the view's scroll tracker; drives the
    /// month/year label and is the anchor the chevrons jump relative to.
    @Published var topVisibleDay: CivilDate = .today

    private let store: ItemStore
    private var windowStart: CivilDate = .today
    private var hasActivatedOnce = false

    init(store: ItemStore = GRDBItemStore.shared) {
        self.store = store
        // Re-fetch the current window whenever a sync commits new calendar
        // data (the app posts this after applying a sync). A windowed view
        // doesn't observe the store live, so this is how the agenda stays
        // current without holding everything in memory.
        NotificationCenter.default.addObserver(
            forName: .calendarItemsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemsChanged() }
        }
    }

    private func handleItemsChanged() {
        guard hasActivatedOnce else { return }
        refresh()
    }

    /// Tab became active. First time: load [today → ∞), anchor today at top.
    /// Every time: refresh the rendered range so newly-synced events appear.
    func activate() {
        if !hasActivatedOnce {
            hasActivatedOnce = true
            windowStart = .today
            load(spinner: true)
            scrollTarget = .today
        } else {
            refresh()
        }
    }

    /// Re-fetch the current range [windowStart → ∞) and regroup, keeping the
    /// scroll position. Also the control-bar refresh glyph's action.
    func refresh() {
        load(spinner: false)
    }

    /// Back chevron: previous Monday above the top day (snap to this week's
    /// Monday if mid-week), loading past days if it's before windowStart.
    func goBack() {
        let top = topVisibleDay
        let thisMonday = top.mondayOfWeek()
        let target = (top == thisMonday) ? thisMonday.adding(days: -7) : thisMonday
        if target < windowStart {
            windowStart = target
            load(spinner: false)   // extends the rendered range into the past
        }
        scrollTarget = target
    }

    /// Forward chevron: next Monday below the top day. Forward data is already
    /// loaded, so this is scroll-only (clamped to the last rendered day).
    func goForward() {
        let nextMonday = topVisibleDay.mondayOfWeek().adding(days: 7)
        scrollTarget = min(nextMonday, days.last?.date ?? nextMonday)
    }

    func goToToday() {
        scrollTarget = .today
    }

    private func load(spinner: Bool) {
        if spinner { isLoading = true } else { isWorking = true }
        do {
            let items = try store.fetchActive(
                type: .calendar, from: windowStart, to: nil
            )
            days = ScheduleAgenda.days(items: items, from: windowStart)
        } catch {
            NSLog("ScheduleAgendaModel: load failed: \(error)")
        }
        isLoading = false
        isWorking = false
    }
}
