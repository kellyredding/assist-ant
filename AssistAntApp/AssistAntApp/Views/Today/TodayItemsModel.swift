import Foundation
import Combine

/// Drives the today sidebar's calendar list. Combines the store's live active
/// calendar feed with the clock so the list refreshes both when items change
/// and on every minute tick — which is what rolls "today" over at midnight and
/// re-evaluates each row's past/upcoming state.
@MainActor
final class TodayItemsModel: ObservableObject {
    @Published private(set) var calendarRows: [TodayCalendarRow] = []

    init(store: ItemStore = GRDBItemStore.shared,
         clock: ClockService = .shared) {
        let items = store.observeActive(type: .calendar).replaceError(with: [])
        Publishers.CombineLatest(items, clock.$currentTime)
            .map { items, now in TodayCalendar.rows(items: items, now: now) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$calendarRows)
    }
}
