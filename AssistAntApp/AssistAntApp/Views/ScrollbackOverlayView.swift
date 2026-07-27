import AppKit
import Combine

/// Container NSView that holds a ScrollbackWebView and a floating pill
/// indicator. Draws a 2px accent-color border around the entire view.
///
/// Galaxy's cross-surface find arbitration is dropped — it exists there to
/// decide which of several sessions and readers owns one shared find panel,
/// and this app has a single scrollback surface to give it to.
class ScrollbackOverlayView: NSView {
    let scrollbackView: ScrollbackWebView
    private let pillLabel: NSTextField

    /// Find controller bound to the inner web view. Reverse iteration means
    /// the first match presented is the most recent one walking up, which is
    /// what a terminal scrollback should do — and why the counter reads
    /// downward from the total.
    let findController: WebViewFindController

    private var findVisibilityCancellable: AnyCancellable?

    /// AppKit-level Esc monitor. The find bar's close button carries a
    /// SwiftUI escape shortcut, but it does not reliably fire from inside an
    /// AppKit hierarchy — the text field's own `cancelOperation:` consumes
    /// Esc first. This catches it at the event stream instead, gated on find
    /// actually being open so a second Esc still reaches the page and
    /// dismisses the overlay.
    private var findEscapeMonitor: Any?

    /// Width of the accent border drawn around the overlay. The web
    /// view is inset by this amount so the border frames the content
    /// rather than covering its edge.
    static let borderWidth: CGFloat = 2

    /// Alpha applied to the border and pill when the owning pane has
    /// lost focus.
    private static let unfocusedAlpha: CGFloat = 0.55

    /// Whether the owning pane holds focus, pushed by
    /// `TerminalHostView` as first responder moves.
    ///
    /// The pane's own dim can't answer this while a scrollback is
    /// open: that dims the live terminal, which the overlay is
    /// covering. Without a signal of its own, two open scrollbacks
    /// look identical and nothing says which one is taking keys.
    ///
    /// Defaults to true because an overlay almost always becomes
    /// first responder the moment it appears.
    var isPaneFocused: Bool = true {
        didSet {
            guard isPaneFocused != oldValue else { return }
            applyAccentTint()
        }
    }

    init(
        frame: NSRect,
        scrollbackView: ScrollbackWebView
    ) {
        self.scrollbackView = scrollbackView
        self.pillLabel = NSTextField(labelWithString: "Scrollback · Esc to exit")
        self.findController = WebViewFindController(
            webView: scrollbackView.webView,
            reverse: true
        )
        super.init(frame: frame)
        wantsLayer = true

        // Add scrollback web view, inset by the border width so the
        // accent border frames the content instead of painting over
        // its first/last row and column. The fixed-margin autoresize
        // mask preserves that inset as the overlay resizes.
        scrollbackView.frame = bounds.insetBy(
            dx: Self.borderWidth, dy: Self.borderWidth
        )
        scrollbackView.autoresizingMask = [.width, .height]
        addSubview(scrollbackView)

        // Configure pill indicator
        configurePill()

        // Draw the accent-color border (applied via applyAccentTint so
        // appearance changes re-tint it too).
        layer?.borderWidth = Self.borderWidth
        applyAccentTint()

        // Find bar, hidden until activateFind(). It anchors to the same
        // top-right slot as the pill, which hides while find is up.
        configureFindBar()
        installFindEscapeMonitor()
    }

    deinit {
        if let monitor = findEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Yield the panel. Without this, any teardown that isn't Esc —
        // sending to Claude, the agent exiting, quitting, discarding notes —
        // leaves the bar floating, bound to a web view that no longer exists.
        //
        // Hopped to the main actor because the panel controller is isolated
        // to it and deinit is not. The controller is captured by value so it
        // outlives this object long enough for the identity check to run;
        // the panel holds it too, which is precisely why it can be stranded.
        let controller = findController
        Task { @MainActor in
            FindBarPanelController.shared.dismiss(if: controller)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pill Indicator

    private func configurePill() {
        pillLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        pillLabel.textColor = contrastingTextColor()
        pillLabel.backgroundColor = NSColor.controlAccentColor
        pillLabel.drawsBackground = true
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.isSelectable = false
        pillLabel.alignment = .center
        pillLabel.sizeToFit()

        // Tight padding — flush against the top-right corner
        let hPadding: CGFloat = 6
        let vPadding: CGFloat = 2
        let pillWidth = pillLabel.frame.width + hPadding * 2
        let pillHeight = pillLabel.frame.height + vPadding * 2

        // Anchor flush to top-right corner (inside the border)
        pillLabel.frame = NSRect(
            x: bounds.width - pillWidth - 1,
            y: bounds.height - pillHeight - 1,
            width: pillWidth,
            height: pillHeight
        )
        pillLabel.autoresizingMask = [.minXMargin, .minYMargin]

        // Vertically center the text within the pill by using a
        // centered baseline offset via the cell's drawing rect
        (pillLabel.cell as? NSTextFieldCell)?.isScrollable = false

        // Square corners matching the terminal view
        pillLabel.wantsLayer = true
        pillLabel.layer?.cornerRadius = 0

        addSubview(pillLabel, positioned: .above, relativeTo: scrollbackView)
    }

    /// Compute contrasting text color based on accent color luminance.
    /// luma = 0.299*r + 0.587*g + 0.114*b; use black if luma > 0.5, white otherwise.
    private func contrastingTextColor() -> NSColor {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return .white
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.5 ? .black : .white
    }

    // MARK: - Event Passthrough

    /// Pill must be transparent to all events (scroll, click, drag) so they
    /// pass through to the ScrollbackWebView underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // If the hit is on the pill, pass through to the web view
        let pointInPill = pillLabel.convert(point, from: self)
        if pillLabel.bounds.contains(pointInPill) {
            return scrollbackView.hitTest(convert(point, to: scrollbackView))
        }
        return super.hitTest(point)
    }

    // MARK: - Find bar

    /// Mirror find visibility into the three things that care: the panel,
    /// the pill, and the page's own key handling.
    ///
    /// The page suspension is the load-bearing one — without it the page
    /// would read Esc as "dismiss scrollback" instead of "close find", and
    /// arrow keys would scroll the buffer out from under the field.
    private func configureFindBar() {
        findVisibilityCancellable = findController.$isVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self = self else { return }
                self.syncFindBarPanel()
                // The pill and the bar want the same corner, and the pill's
                // "Esc to exit" is a lie while find owns Esc.
                self.pillLabel.isHidden = visible
                self.scrollbackView.webView.evaluateJavaScript(
                    "if (typeof ScrollbackManager !== 'undefined') { "
                        + "ScrollbackManager.suspendInput(\(visible)); }"
                )
            }
    }

    private func syncFindBarPanel() {
        guard findController.isVisible else {
            FindBarPanelController.shared.dismiss(if: findController)
            return
        }
        FindBarPanelController.shared.present(
            controller: findController, anchorView: self
        )
    }

    /// Bring up the find bar. Safe to call when it is already visible: the
    /// publisher emits on every assignment, not only on change, so this
    /// re-presents and refocuses the field — which is what a ⌘F re-press
    /// should do.
    func activateFind() {
        findController.isVisible = true
    }

    private func installFindEscapeMonitor() {
        findEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self = self,
                  event.keyCode == 53,
                  self.findController.isVisible
            else { return event }
            self.findController.isVisible = false
            return nil
        }
    }

    // MARK: - Dynamic Accent Color

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Update border + pill colors when the accent color changes.
        applyAccentTint()
        pillLabel.textColor = contrastingTextColor()
    }

    /// Apply the accent color to the border + pill background, at the
    /// alpha the current focus state calls for. Single source of
    /// truth so focus changes and appearance changes always agree.
    private func applyAccentTint() {
        let alpha: CGFloat = isPaneFocused ? 1.0 : Self.unfocusedAlpha
        let tinted = NSColor.controlAccentColor
            .withAlphaComponent(alpha)
        layer?.borderColor = tinted.cgColor
        pillLabel.backgroundColor = tinted
    }
}
