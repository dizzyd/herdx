import AppKit
import CHerdrCore

struct TerminalLink: Equatable {
    let url: URL
    let paneID: String
    /// Cell spans in surface coordinates; end is exclusive.
    let spans: [CellSpan]

    struct CellSpan: Equatable {
        let row: Int
        let columns: Range<Int>

        func contains(_ column: Int, _ row: Int) -> Bool {
            self.row == row && columns.contains(column)
        }
    }

    func contains(_ column: Int, _ row: Int) -> Bool {
        spans.contains { $0.contains(column, row) }
    }
}

enum TerminalLinks {
    private static let urlPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"'`]+"#, options: .caseInsensitive)

    static func safeURL(_ text: String) -> URL? {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://")
        else { return nil }
        guard let url = URL(string: text),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil,
            !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
            !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        return url
    }

    /// Inspect one row only. Keep a UTF-16 offset per cell so regex ranges map
    /// back to columns even when a glyph contains multiple code units.
    static func printed(in glyphs: [String], column: Int) -> (url: URL, columns: Range<Int>)? {
        guard glyphs.indices.contains(column) else { return nil }
        var text = ""
        var length = 0
        var offsets: [Range<Int>] = []
        for glyph in glyphs {
            let start = length
            text += glyph
            length += glyph.utf16.count
            offsets.append(start..<length)
        }
        guard let urlPattern else { return nil }
        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: length)) {
            let raw = (text as NSString).substring(with: match.range)
            var candidate = raw
            while let last = candidate.last {
                let trim = ".,;:!?".contains(last)
                    || (last == ")" && candidate.filter { $0 == ")" }.count > candidate.filter { $0 == "(" }.count)
                    || (last == "]" && candidate.filter { $0 == "]" }.count > candidate.filter { $0 == "[" }.count)
                    || (last == "}" && candidate.filter { $0 == "}" }.count > candidate.filter { $0 == "{" }.count)
                if !trim { break }
                candidate.removeLast()
            }
            guard let url = safeURL(candidate) else { continue }
            let end = match.range.location + (candidate as NSString).length
            guard let first = offsets.firstIndex(where: {
                $0.lowerBound == match.range.location && !$0.isEmpty
            }), let last = offsets.lastIndex(where: { $0.upperBound == end && !$0.isEmpty })
            else { continue }
            // A continuation cell shares the previous glyph's visual width.
            // A click there belongs to the same matched URL.
            var upper = last + 1
            while upper < glyphs.count, glyphs[upper].isEmpty { upper += 1 }
            if (first..<upper).contains(column) { return (url, first..<upper) }
        }
        return nil
    }

    static func resolve(_ grid: GridView, pane: PaneView, column: Int, row: Int) -> TerminalLink? {
        let rect = pane.inner
        guard column >= rect.x, column < rect.x + rect.width,
            row >= rect.y, row < rect.y + rect.height,
            column < grid.width, row < grid.height,
            grid.cells.count >= grid.width * grid.height else { return nil }
        func cell(_ x: Int, _ y: Int) -> HxCell { grid.cells[y * grid.width + x] }
        guard !CellStyle(rawValue: cell(column, row).modifier).contains(.hidden) else { return nil }
        func linkIndex(_ x: Int, _ y: Int) -> UInt32 {
            let current = cell(x, y)
            if current.hyperlink != UInt32.max { return current.hyperlink }
            // The blank continuation of a wide glyph may lack link metadata.
            if x > rect.x, current.glyph_len == 0,
                cell(x - 1, y).hyperlink != UInt32.max {
                return cell(x - 1, y).hyperlink
            }
            return UInt32.max
        }
        let index = linkIndex(column, row)
        if index != UInt32.max {
            guard let target = grid.hyperlink(at: Int(index)),
                let url = safeURL(target) else { return nil }
            let width = rect.width
            let clicked = (row - rect.y) * width + column - rect.x
            func matches(_ position: Int) -> Bool {
                let x = rect.x + position % width
                let y = rect.y + position / width
                return x < grid.width && y < grid.height
                    && !CellStyle(rawValue: cell(x, y).modifier).contains(.hidden)
                    && linkIndex(x, y) == index
            }
            // Each direction is bounded separately so a link filling a large
            // window stays clickable: the walk only decides how much of it is
            // underlined, and the clicked cell is always inside what it finds.
            let reach = 4096
            var start = clicked, end = clicked
            while start > 0, clicked - start < reach, matches(start - 1) { start -= 1 }
            while end + 1 < width * rect.height, end - clicked < reach, matches(end + 1) { end += 1 }
            var spans: [TerminalLink.CellSpan] = []
            for localRow in start / width...end / width {
                let from = localRow == start / width ? start % width : 0
                let to = localRow == end / width ? end % width + 1 : width
                spans.append(.init(row: rect.y + localRow, columns: (rect.x + from)..<(rect.x + to)))
            }
            return TerminalLink(url: url, paneID: pane.id, spans: spans)
        }
        let right = min(rect.x + rect.width, grid.width)
        let bottom = min(rect.y + rect.height, grid.height)
        func glyphs(of y: Int) -> [String] {
            (rect.x..<right).map { x -> String in
                let current = cell(x, y)
                // Wide glyph continuations are empty cells in the surface and
                // must not introduce a character or shift the URL's columns.
                if CellStyle(rawValue: current.modifier).contains(.hidden) { return " " }
                return current.glyph_len == 0 ? "" : grid.glyph(current)
            }
        }
        // The surface carries no soft-wrap flag, so a wrap is inferred the way
        // iTerm and Ghostty infer it: a row whose text runs to the pane's edge
        // continues on the next. One blank of slack covers the column herdr
        // keeps free at the edge. Joining these rows is what makes a wrapped
        // URL open the address on screen rather than the part on this row.
        func wraps(_ row: [String]) -> Bool {
            guard let last = row.lastIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) else { return false }
            return last >= row.count - 2
        }
        let maxRows = 8
        var top = row
        while top > rect.y, row - top < maxRows, wraps(glyphs(of: top - 1)) { top -= 1 }
        var last = row
        while last + 1 < bottom, last - row < maxRows, wraps(glyphs(of: last)) { last += 1 }

        var joined: [String] = []
        var positions: [(row: Int, column: Int)] = []
        var clicked: Int?
        for y in top...last {
            var line = glyphs(of: y)
            // Drop the slack blank on a wrapped row so the halves meet.
            if y < last, line.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                line.removeLast()
            }
            for (offset, glyph) in line.enumerated() {
                if y == row, rect.x + offset == column { clicked = joined.count }
                joined.append(glyph)
                positions.append((y, rect.x + offset))
            }
        }
        guard let clicked, let found = printed(in: joined, column: clicked) else { return nil }

        var spans: [TerminalLink.CellSpan] = []
        for index in found.columns {
            let position = positions[index]
            if let previous = spans.last, previous.row == position.row,
                previous.columns.upperBound == position.column {
                spans[spans.count - 1] = .init(
                    row: position.row, columns: previous.columns.lowerBound..<(position.column + 1))
            } else {
                spans.append(.init(row: position.row, columns: position.column..<(position.column + 1)))
            }
        }
        return TerminalLink(url: found.url, paneID: pane.id, spans: spans)
    }
}
