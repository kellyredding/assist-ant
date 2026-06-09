import AppKit
import SwiftUI

/// The event body, rendered with AppKit so links behave natively: the
/// pointing-hand cursor over a link, an on-hover underline, click-to-open, and
/// selectable body text. (SwiftUI `Text` renders the Markdown link but offers
/// no link cursor and no hover affordance.) Wraps an `NSTextView` in its own
/// `NSScrollView`, so it sizes and scrolls without fighting a SwiftUI
/// `ScrollView`.
struct EventBodyTextView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // Build an explicit TextKit 1 stack so `layoutManager` is available for
        // glyph hit-testing and temporary (hover) attributes — a plain
        // NSTextView defaults to TextKit 2, where `layoutManager` is nil.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = HoverLinkTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isAutomaticLinkDetectionEnabled = false
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.linkTextAttributes = linkAttributes
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(Self.attributed(markdown))

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        context.coordinator.lastMarkdown = markdown
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Only re-set on an actual content change, so unrelated SwiftUI updates
        // don't clobber the user's selection or scroll position.
        guard context.coordinator.lastMarkdown != markdown,
              let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(Self.attributed(markdown))
        context.coordinator.lastMarkdown = markdown
    }

    /// Markdown → attributed text: inline-only parsing (preserves the
    /// composer's per-field line breaks and links the bracketed URLs), then the
    /// body font + label color applied across the whole string. Link runs keep
    /// their `.link` attribute, which `linkTextAttributes` styles at display.
    private static func attributed(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let result: NSMutableAttributedString
        if let parsed = try? NSAttributedString(markdown: markdown, options: options) {
            result = NSMutableAttributedString(attributedString: parsed)
        } else {
            result = NSMutableAttributedString(string: markdown)
        }
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(
            .font, value: NSFont.preferredFont(forTextStyle: .body), range: full
        )
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        return result
    }

    final class Coordinator {
        var lastMarkdown: String?
    }
}

/// NSTextView that underlines the link under the pointer while it's hovered,
/// via temporary layout attributes (the stored string is left untouched). The
/// pointing-hand cursor over links comes from `linkTextAttributes`.
private final class HoverLinkTextView: NSTextView {
    private var hoveredRange: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let range = linkRange(at: point) {
            setHover(range)
        } else {
            clearHover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    /// The `.link` run under `point`, but only when the pointer is genuinely
    /// over a linked glyph (not merely near one at the end of a line).
    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let cp = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var frac: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: cp, in: textContainer, fractionOfDistanceThroughGlyph: &frac
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
        )
        guard glyphRect.contains(cp) else { return nil }
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        guard char < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(.link, at: char, effectiveRange: &range) != nil
        else { return nil }
        return range
    }

    private func setHover(_ range: NSRange) {
        guard hoveredRange != range else { return }
        clearHover()
        hoveredRange = range
        layoutManager?.addTemporaryAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue,
            forCharacterRange: range
        )
    }

    private func clearHover() {
        guard let range = hoveredRange else { return }
        layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        hoveredRange = nil
    }
}
