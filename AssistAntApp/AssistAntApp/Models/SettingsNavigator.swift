import Combine
import Foundation

/// Shared selection state for the Settings modal's tab strip.
///
/// `PreferencesWindowController`'s hosting controller and
/// `SettingsView` are both singletons that live across the modal's
/// lifetime, so a `@State`-driven initial-tab choice wouldn't pick
/// up second-and-later opens (the State init only runs once). This
/// navigator gives any caller — status button click, menu bar item,
/// future deep links — a write path to the active tab, and
/// `SettingsView` observes it via `@ObservedObject`.
///
/// Also acts as the persistence-free memory of which tab was open
/// last: if the user picks Time, closes Settings, then opens Settings
/// again with no `initialTab:` argument, they land back on Time.
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var selectedTab: SettingsTab = .general

    private init() {}
}
