import CHerdrCore
import Foundation

/// Everything the UI knows about one pane in the current surface.
struct PaneView {
    let id: String
    let rect: CellRect
    let inner: CellRect
    let focused: Bool
    let alternateScreen: Bool
}

struct CellRect {
    var x: Int, y: Int, width: Int, height: Int
}

/// A borrowed view of the current surface. Only valid inside `withGrid`.
struct GridView {
    let width: Int
    let height: Int
    let cells: UnsafeBufferPointer<HxCell>
    let glyphs: UnsafeBufferPointer<UInt8>
    let cursor: (x: Int, y: Int, visible: Bool, shape: UInt8)
    let revision: UInt64
    let panes: [PaneView]

    /// The grapheme cluster for a cell, decoded from the side buffer.
    func glyph(_ cell: HxCell) -> String {
        guard cell.glyph_len > 0, let base = glyphs.baseAddress else { return " " }
        let bytes = UnsafeBufferPointer(
            start: base + Int(cell.glyph_off), count: Int(cell.glyph_len))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Owns the connection to the herdr server.
///
/// The Rust core runs the socket on its own thread; this type is the polling
/// face of it. All calls must come from the main thread.
final class HerdrSession {
    private var handle: OpaquePointer?
    private(set) var lastSnapshot: Snapshot?

    enum ConnectError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    init(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws {
        handle = hx_session_connect(
            UInt16(cols), UInt16(rows), UInt32(cellWidth), UInt32(cellHeight))
        guard handle != nil else {
            throw ConnectError.failed(Self.take(hx_connect_error()) ?? "could not reach herdr")
        }
    }

    deinit {
        if let handle { hx_session_free(handle) }
    }

    var isConnected: Bool { handle.map { hx_session_connected($0) } ?? false }

    /// Runs `body` with the current surface, or returns nil if none has arrived.
    ///
    /// The pointers are owned by the core and are invalidated by the next
    /// acquire, so they must not escape the closure.
    func withGrid<T>(_ body: (GridView) -> T) -> T? {
        guard let handle else { return nil }
        var raw = HxGrid()
        guard hx_grid_acquire(handle, &raw) else { return nil }

        let panes = (0..<raw.pane_count).map { i -> PaneView in
            let p = raw.panes[i]
            return PaneView(
                id: Self.take(hx_pane_id(handle, p.id_index)) ?? "",
                rect: CellRect(
                    x: Int(p.x), y: Int(p.y), width: Int(p.width), height: Int(p.height)),
                inner: CellRect(
                    x: Int(p.inner_x), y: Int(p.inner_y),
                    width: Int(p.inner_width), height: Int(p.inner_height)),
                focused: p.focused,
                alternateScreen: p.alternate_screen)
        }

        return body(
            GridView(
                width: Int(raw.width),
                height: Int(raw.height),
                cells: UnsafeBufferPointer(start: raw.cells, count: raw.cell_count),
                glyphs: UnsafeBufferPointer(start: raw.glyphs, count: raw.glyph_bytes),
                cursor: (Int(raw.cursor_x), Int(raw.cursor_y), raw.cursor_visible, raw.cursor_shape),
                revision: raw.revision,
                panes: panes))
    }

    /// Picks up a new snapshot if one arrived. Returns true when it changed.
    @discardableResult
    func pollSnapshot() -> Bool {
        guard let handle, let json = Self.take(hx_take_snapshot_json(handle)) else { return false }
        guard let data = json.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return false }
        lastSnapshot = snapshot
        return true
    }

    /// Drains queued server events, oldest first.
    func drainEvents() -> [ServerEvent] {
        guard let handle else { return [] }
        var events: [ServerEvent] = []
        let decoder = JSONDecoder()
        while let json = Self.take(hx_next_event(handle)) {
            guard let data = json.data(using: .utf8),
                let event = try? decoder.decode(ServerEvent.self, from: data)
            else { continue }
            events.append(event)
        }
        return events
    }

    func takeError() -> String? {
        guard let handle else { return nil }
        return Self.take(hx_last_error(handle))
    }

    func send(key: UInt16, codepoint: UInt32 = 0, modifiers: UInt8 = 0, to pane: String) {
        guard let handle else { return }
        _ = pane.withCString { hx_send_key(handle, $0, key, codepoint, modifiers) }
    }

    func send(text: String, to pane: String) {
        guard let handle else { return }
        _ = pane.withCString { p in text.withCString { t in hx_send_text(handle, p, t) } }
    }

    func send(mouse: HxMouseEvent, to pane: String) {
        guard let handle else { return }
        var event = mouse
        _ = pane.withCString { hx_send_mouse(handle, $0, &event) }
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard let handle else { return }
        _ = hx_resize(handle, UInt16(cols), UInt16(rows), UInt32(cellWidth), UInt32(cellHeight))
    }

    /// Invokes one of herdr's 38 endpoint methods.
    func request(_ json: String, bootID: String) {
        guard let handle else { return }
        _ = bootID.withCString { b in json.withCString { r in hx_endpoint_request(handle, b, r) } }
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { hx_string_free(pointer) }
        return String(cString: pointer)
    }
}
