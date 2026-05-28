import SwiftUI

/// Root content of the main AssistAnt window. Currently just the
/// clock, which now hosts the announcement status icon inline with
/// the time. Future widgets (next upcoming reminder, standing-desk
/// timer, todo preview) compose alongside as the feature surface
/// grows.
struct ContentView: View {
    var body: some View {
        ClockView()
    }
}
