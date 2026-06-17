import Foundation

/// The captured spend display state, composed entirely by the embedded agent and
/// stored as JSON on the workspace record. The app is a pure renderer: `primary`
/// and `secondary` are free-form pill strings (e.g. "$392 today", "$2.7k mo"),
/// `variants` are the labeled monospaced report blocks shown as popover cards,
/// and `capturedAt` drives the stale indicator. Nothing here is parsed app-side.
struct SpendState: Codable, Equatable {
    var primary: String?
    var secondary: String?
    var capturedAt: Date
    var variants: [Variant]

    struct Variant: Codable, Equatable {
        var label: String   // card title, e.g. "Month to Date"
        var body: String    // the raw /spend block (monospaced), verbatim
    }
}
