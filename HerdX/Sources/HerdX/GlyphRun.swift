import AppKit
import CoreText

/// Draws runs of terminal cells with explicit glyph positions.
///
/// Two reasons not to just hand AppKit a string per cell. It allocates an
/// attributed string and runs the whole text pipeline thousands of times a
/// frame; and, more subtly, a monospace font's advance is rarely exactly the
/// integral cell width we snap the grid to, so letting the text engine place
/// glyphs makes a long run drift out of its columns. Positioning every glyph at
/// its own cell origin fixes the column alignment *and* collapses a row into
/// one draw call.
struct GlyphRunDrawer {
    private let font: CTFont
    private let boldFont: CTFont
    private let italicFont: CTFont
    private let boldItalicFont: CTFont
    let cellSize: CGSize
    let ascent: CGFloat

    init(pointSize: CGFloat) {
        let base = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        font = base
        boldFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        italicFont =
            CTFontCreateCopyWithSymbolicTraits(base, pointSize, nil, .italicTrait, .italicTrait)
            ?? base
        boldItalicFont =
            CTFontCreateCopyWithSymbolicTraits(
                NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold),
                pointSize, nil, .italicTrait, .italicTrait)
            ?? boldFont

        // Measure a real glyph rather than the font's maximum advance, which
        // in a monospace face can be wider than the actual cell.
        var digit: CGGlyph = 0
        let advance: CGFloat
        if CTFontGetGlyphsForCharacters(base, [UniChar(UnicodeScalar("0").value)], &digit, 1) {
            advance = CTFontGetAdvancesForGlyphs(base, .horizontal, &digit, nil, 1)
        } else {
            advance = base.maximumAdvancement.width
        }

        // Cells must land on whole pixels or the grid shimmers during scroll.
        let height = CTFontGetAscent(base) + CTFontGetDescent(base) + CTFontGetLeading(base)
        cellSize = CGSize(
            width: advance.rounded(.up),
            height: max(height.rounded(.up), 1))
        ascent = CTFontGetAscent(base)
    }

    func font(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (true, true): return boldItalicFont
        case (true, false): return boldFont
        case (false, true): return italicFont
        case (false, false): return font
        }
    }

    /// Draws `text` starting at `column`, one glyph per cell.
    ///
    /// Returns the cells it could not render, which the caller draws through
    /// AppKit so font fallback applies (emoji, box drawing the base font lacks).
    func draw(
        cells: [(column: Int, text: String)],
        row: Int,
        font: CTFont,
        color: NSColor,
        in context: CGContext
    ) -> [(column: Int, text: String)] {
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var fallback: [(column: Int, text: String)] = []
        glyphs.reserveCapacity(cells.count)
        positions.reserveCapacity(cells.count)

        for cell in cells {
            let units = Array(cell.text.utf16)
            // One UTF-16 unit means a simple glyph we can place ourselves;
            // anything else is a cluster and belongs on the fallback path.
            guard units.count == 1 else {
                fallback.append(cell)
                continue
            }
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, units, &glyph, 1), glyph != 0 else {
                fallback.append(cell)
                continue
            }
            glyphs.append(glyph)
            // The text matrix below flips y, and it applies to these positions
            // as well as to the glyph outlines, so pre-negate the baseline.
            positions.append(
                CGPoint(
                    x: CGFloat(cell.column) * cellSize.width,
                    y: -(CGFloat(row) * cellSize.height + ascent)))
        }

        guard !glyphs.isEmpty else { return fallback }

        context.saveGState()
        context.setFillColor(color.cgColor)
        // The view is flipped, so undo the vertical flip for glyphs only;
        // without this they render upside down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
        context.restoreGState()

        return fallback
    }
}
