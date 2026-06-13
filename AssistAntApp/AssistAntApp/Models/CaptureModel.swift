import Foundation

/// Observable state for an open Quick Capture popover. Lifting `kind` out of
/// `CaptureContentView`'s local `@State` lets `CapturePanelController` summon
/// the popover preset to a kind and switch kinds on an already-open popover
/// (e.g. pressing the To-do shortcut while Ask is showing) without tearing the
/// view down — which is what keeps Wispr auto-arm tied to the summon path
/// rather than to kind selection.
final class CaptureModel: ObservableObject {
    @Published var kind: CaptureKind

    init(kind: CaptureKind) {
        self.kind = kind
    }
}
