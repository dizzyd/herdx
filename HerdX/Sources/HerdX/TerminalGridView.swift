import AppKit
import CHerdrCore

/// Draws the pane surface herdr sends us.
///
/// The server composes one grid for the whole active tab and reports where each
/// pane sits inside it. This view draws that single grid, but every span is
/// routed through its owning pane first, so panes can become real `NSView`s
/// later without changing how surfaces or patches are delivered.
final class TerminalGridView: NSView {
    var session: HerdrSession?
    var theme: Theme = .default
    var onResize: ((Int, Int) -> Void)?

    private(set) var cellSize: CGSize = .zero
    private var font: NSFont
    private var boldFont: NSFont
    private var lastRevision: UInt64 = .max
    private var focusedPaneID: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(pointSize: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        super.init(frame: .zero)
        measureCell()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Cell metrics come from the font's advance, so the grid stays aligned
    /// with what the server thinks a cell is.
    private func measureCell() {
        let advance = font.maximumAdvancement.width
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        cellSize = CGSize(width: ceil(advance), height: max(lineHeight, 1))
    }

    var gridSize: (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        return (
            max(Int(bounds.width / cellSize.width), 1),
            max(Int(bounds.height / cellSize.height), 1)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let (cols, rows) = gridSize
        onResize?(cols, rows)
    }

    /// Called each tick; only repaints when the surface actually advanced.
    func refreshIfNeeded() {
        guard let session else { return }
        let revision = session.withGrid { $0.revision }
        guard let revision, revision != lastRevision else { return }
        lastRevision = revision
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        theme.background.setFill()
        context.fill(dirtyRect)

        guard let session else { return }
        session.withGrid { grid in
            focusedPaneID = grid.panes.first(where: \.focused)?.id

            // Route by pane so the per-pane seam stays real even with one view.
            if grid.panes.isEmpty {
                drawRegion(grid, CellRect(x: 0, y: 0, width: grid.width, height: grid.height),
                           in: context)
            } else {
                for pane in grid.panes {
                    drawRegion(grid, pane.rect, in: context)
                }
            }
            drawCursor(grid, in: context)
        }
    }

    private func drawRegion(_ grid: GridView, _ region: CellRect, in context: CGContext) {
        let maxY = min(region.y + region.height, grid.height)
        let maxX = min(region.x + region.width, grid.width)
        guard maxX > region.x, maxY > region.y else { return }

        for row in region.y..<maxY {
            // Runs of identical background paint in one fill.
            var runStart = region.x
            var runColor: NSColor?

            for col in region.x..<maxX {
                let cell = grid.cells[row * grid.width + col]
                let style = CellStyle(rawValue: cell.modifier)
                let bg = resolvedBackground(cell, style: style)

                if bg != runColor {
                    flushBackground(runColor, from: runStart, to: col, row: row, in: context)
                    runStart = col
                    runColor = bg
                }
            }
            flushBackground(runColor, from: runStart, to: maxX, row: row, in: context)

            for col in region.x..<maxX {
                drawGlyph(grid, row: row, col: col, in: context)
            }
        }
    }

    private func resolvedBackground(_ cell: HxCell, style: CellStyle) -> NSColor {
        let bg = PackedColor(cell.bg, theme: theme, isForeground: false)
        let fg = PackedColor(cell.fg, theme: theme, isForeground: true)
        return style.contains(.reversed)
            ? fg.resolved(theme: theme, isForeground: true)
            : bg.resolved(theme: theme, isForeground: false)
    }

    private func flushBackground(
        _ color: NSColor?, from startCol: Int, to endCol: Int, row: Int, in context: CGContext
    ) {
        guard let color, endCol > startCol, color != theme.background else { return }
        color.setFill()
        context.fill(
            CGRect(
                x: CGFloat(startCol) * cellSize.width,
                y: CGFloat(row) * cellSize.height,
                width: CGFloat(endCol - startCol) * cellSize.width,
                height: cellSize.height))
    }

    private func drawGlyph(_ grid: GridView, row: Int, col: Int, in context: CGContext) {
        let cell = grid.cells[row * grid.width + col]
        let style = CellStyle(rawValue: cell.modifier)
        guard !style.contains(.hidden) else { return }

        let glyph = grid.glyph(cell)
        guard !glyph.isEmpty, glyph != " " else { return }

        let fgPacked = PackedColor(cell.fg, theme: theme, isForeground: true)
        let bgPacked = PackedColor(cell.bg, theme: theme, isForeground: false)
        var color =
            style.contains(.reversed)
            ? bgPacked.resolved(theme: theme, isForeground: false)
            : fgPacked.resolved(theme: theme, isForeground: true)
        if style.contains(.dim) {
            color = color.withAlphaComponent(0.55)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.contains(.bold) ? boldFont : font,
            .foregroundColor: color,
        ]
        if style.contains(.underlined) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.crossedOut) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.italic) {
            attributes[.obliqueness] = 0.2
        }

        let origin = CGPoint(
            x: CGFloat(col) * cellSize.width,
            y: CGFloat(row) * cellSize.height)
        NSAttributedString(string: glyph, attributes: attributes).draw(at: origin)
    }

    private func drawCursor(_ grid: GridView, in context: CGContext) {
        guard grid.cursor.visible, window?.isKeyWindow == true else { return }
        let rect = CGRect(
            x: CGFloat(grid.cursor.x) * cellSize.width,
            y: CGFloat(grid.cursor.y) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height)
        theme.foreground.withAlphaComponent(0.75).setFill()
        // DECSCUSR: 3/4 underline, 5/6 bar, everything else block.
        switch grid.cursor.shape {
        case 3, 4:
            context.fill(
                CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case 5, 6:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        default:
            context.fill(rect)
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        guard let session, let pane = focusedPaneID else { return }
        guard let mapped = KeyMapper.map(event) else {
            // Anything we do not classify travels as committed text, which lets
            // IME and dead keys work without us re-implementing composition.
            if let text = event.characters, !text.isEmpty {
                session.send(text: text, to: pane)
            }
            return
        }
        session.send(
            key: mapped.kind, codepoint: mapped.codepoint, modifiers: mapped.modifiers, to: pane)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
}
