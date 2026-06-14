import AppKit

/// Markdown → attributed text with block-level rendering, shared by the item
/// reader's body (`EventBodyTextView`) and the hover tooltip
/// (`TooltipMarkdownBody`) so both render content identically.
///
/// Full CommonMark parsing gives the block structure; we then walk the parsed
/// `presentationIntent` to style each block — heading sizes, list bullets /
/// numbers (with `[ ]`/`[x]` task items shown as checkboxes), code blocks, and
/// block quotes — joining blocks with styled newlines so spacing holds. Inline
/// emphasis/code and links are preserved; link runs keep their `.link`
/// attribute, which the host's `linkTextAttributes` styles at display. Falls
/// back to plain text if parsing fails.
enum MarkdownText {
    static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    static func attributed(_ markdown: String) -> NSAttributedString {
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
}
