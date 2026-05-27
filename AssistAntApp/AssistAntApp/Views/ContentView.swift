import SwiftUI

/// Root content of the main AssistAnt window. Currently just the clock;
/// future widgets (next upcoming reminder, standing-desk timer, todo
/// preview) compose alongside as the feature surface grows.
struct ContentView: View {
    var body: some View {
        ClockView()
    }
}
