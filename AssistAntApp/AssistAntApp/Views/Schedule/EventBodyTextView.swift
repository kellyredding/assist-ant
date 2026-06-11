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

    private static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    /// Markdown → attributed text with block-level rendering. Full CommonMark
    /// parsing gives the block structure; we then walk the parsed
    /// `presentationIntent` to style each block — heading sizes, list bullets /
    /// numbers (with `[ ]`/`[x]` task items shown as checkboxes), code blocks,
    /// and block quotes — joining blocks with styled newlines so spacing holds.
    /// Inline emphasis/code and links are preserved; link runs keep their
    /// `.link` attribute, which `linkTextAttributes` styles at display. Falls
    /// back to plain text if parsing fails.
    private static func attributed(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return plainText(markdown)
        }

        // Group runs into blocks: contiguous runs sharing the same block intent.
        var blocks: [(intent: PresentationIntent?, text: NSMutableAttributedString)] = []
        for run in parsed.runs {
            let slice = String(parsed[run.range].characters)
            guard !slice.isEmpty else { continue }
            let piece = inlineStyled(slice, run: run)
            if let last = blocks.last, last.intent == run.presentationIntent {
                last.text.append(piece)
            } else {
                blocks.append((run.presentationIntent,
                               NSMutableAttributedString(attributedString: piece)))
            }
        }

        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let rendered = renderBlock(block.intent, text: block.text)
            out.append(rendered)
            guard i < blocks.count - 1 else { continue }
            // Terminate the paragraph carrying its style onto the newline, so
            // paragraphSpacing applies between blocks.
            let para = (rendered.length > 0
                ? rendered.attribute(.paragraphStyle, at: rendered.length - 1,
                                     effectiveRange: nil)
                : nil) as? NSParagraphStyle
            var nl: [NSAttributedString.Key: Any] = [.font: bodyFont]
            if let para { nl[.paragraphStyle] = para }
            out.append(NSAttributedString(string: "\n", attributes: nl))
        }
        return out.length > 0 ? out : plainText(markdown)
    }

    private static func plainText(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
        ])
    }

    /// One run → attributed text: body font adjusted for inline emphasis/code,
    /// label color, and any link URL carried through.
    private static func inlineStyled(
        _ text: String, run: AttributedString.Runs.Run
    ) -> NSAttributedString {
        var font = bodyFont
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if inline.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        if let link = run.link { attrs[.link] = link }
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// Apply block-level styling (font, prefix, indentation, spacing) from the
    /// block's presentation intent, returning the finished paragraph.
    private static func renderBlock(
        _ intent: PresentationIntent?, text: NSMutableAttributedString
    ) -> NSAttributedString {
        let comps = intent?.components ?? []
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        let whole = { NSRange(location: 0, length: text.length) }

        // Heading.
        if let level = headerLevel(comps) {
            let size = bodyFont.pointSize + headerBump(level)
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: whole())
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 4
            text.addAttribute(.paragraphStyle, value: style, range: whole())
            return text
        }

        // Fenced/indented code block.
        if comps.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) {
            text.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
                range: whole())
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            text.addAttribute(.paragraphStyle, value: style, range: whole())
            return text
        }

        // List item (ordered or unordered; task items become checkboxes).
        if let depth = listDepth(comps), depth > 0 {
            let ordered = comps.contains {
                if case .orderedList = $0.kind { return true }; return false
            }
            let indent = CGFloat(depth) * 18
            let tab = indent + 18
            style.firstLineHeadIndent = indent
            style.headIndent = tab
            style.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
            style.paragraphSpacing = 3

            let marker = listMarker(text: text, ordered: ordered, ordinal: listOrdinal(comps))
            text.addAttribute(.paragraphStyle, value: style, range: whole())
            let composed = NSMutableAttributedString(string: marker, attributes: [
                .font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
            composed.append(text)
            return composed
        }

        // Block quote.
        if comps.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: whole())
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            text.addAttribute(.paragraphStyle, value: style, range: whole())
            return text
        }

        // Plain paragraph.
        text.addAttribute(.paragraphStyle, value: style, range: whole())
        return text
    }

    /// The leading marker for a list item. A leading `[ ]` / `[x]` (task list)
    /// is stripped from `text` and rendered as a checkbox glyph instead.
    private static func listMarker(
        text: NSMutableAttributedString, ordered: Bool, ordinal: Int
    ) -> String {
        for (token, glyph) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] {
            if text.string.hasPrefix(token) {
                text.deleteCharacters(in: NSRange(location: 0, length: 4))
                return "\(glyph)\t"
            }
        }
        return ordered ? "\(ordinal).\t" : "•\t"
    }

    private static func headerLevel(_ comps: [PresentationIntent.IntentType]) -> Int? {
        for c in comps { if case .header(let level) = c.kind { return level } }
        return nil
    }

    private static func headerBump(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 5
        case 3: return 3
        default: return 1
        }
    }

    private static func listDepth(_ comps: [PresentationIntent.IntentType]) -> Int? {
        comps.reduce(0) { acc, c in
            switch c.kind {
            case .orderedList, .unorderedList: return acc + 1
            default: return acc
            }
        }
    }

    private static func listOrdinal(_ comps: [PresentationIntent.IntentType]) -> Int {
        for c in comps { if case .listItem(let ord) = c.kind { return ord } }
        return 1
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
