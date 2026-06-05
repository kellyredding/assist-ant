import AppKit

/// Container NSView that holds a ScrollbackWebView and a floating pill
/// indicator. Draws a 2px accent-color border around the entire view.
///
/// Collapsed for AssistAnt's single embedded session: Galaxy's
/// shared find-bar arbitration (`findController` /
/// `FindBarPanelController` / `WebViewFindController`) and the
/// `isActiveSurface` focus-tint predicate are dropped — there is only
/// one terminal surface, so the border + pill stay at full accent
/// tint and there is no Cmd+F find module to host.
class ScrollbackOverlayView: NSView {
    let scrollbackView: ScrollbackWebView
    private let pillLabel: NSTextField

    init(
        frame: NSRect,
        scrollbackView: ScrollbackWebView
    ) {
        self.scrollbackView = scrollbackView
        self.pillLabel = NSTextField(labelWithString: "Scrollback · Esc to exit")
        super.init(frame: frame)
        wantsLayer = true

        // Add scrollback web view filling the entire frame
        scrollbackView.frame = bounds
        scrollbackView.autoresizingMask = [.width, .height]
        addSubview(scrollbackView)

        // Configure pill indicator
        configurePill()

        // Draw 2px accent-color border (applied via applyAccentTint so
        // appearance changes re-tint it too).
        layer?.borderWidth = 2
        applyAccentTint()
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

    // MARK: - Dynamic Accent Color

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Update border + pill colors when the accent color changes.
        applyAccentTint()
        pillLabel.textColor = contrastingTextColor()
    }

    /// Apply the accent color to the border + pill background. Single
    /// source of truth so appearance changes always agree.
    private func applyAccentTint() {
        let tinted = NSColor.controlAccentColor
        layer?.borderColor = tinted.cgColor
        pillLabel.backgroundColor = tinted
    }
}
