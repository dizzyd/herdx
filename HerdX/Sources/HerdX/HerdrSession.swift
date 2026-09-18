import CHerdrCore
import CoreGraphics
import Foundation
import ImageIO

/// Everything the UI knows about one pane in the current surface.
struct PaneView {
    let id: String
    let rect: CellRect
    let inner: CellRect
    let focused: Bool
    let alternateScreen: Bool
    /// True while the pane's program wants mouse events itself.
    let mouseReporting: Bool
    let scrollOffsetFromBottom: UInt64
    let scrollMaxOffsetFromBottom: UInt64
    let contentRevision: UInt64

    /// The scrollback row showing at the top of this pane's viewport.
    ///
    /// `pane.selection.read` addresses text in absolute scrollback
    /// coordinates, so a viewport row has to be offset by however far back the
    /// pane is scrolled.
    var viewportTopRow: UInt64 {
        scrollMaxOffsetFromBottom >= scrollOffsetFromBottom
            ? scrollMaxOffsetFromBottom - scrollOffsetFromBottom : 0
    }
}

struct CellRect {
    var x: Int, y: Int, width: Int, height: Int
}

/// A borrowed view of the current surface. Only valid inside `withGrid`.
/// An image the server placed in a pane.
struct Placement {
    let assetID: UInt64
    let x: Int, y: Int
    let cols: Int, rows: Int
    let sourceX: Int, sourceY: Int, sourceWidth: Int, sourceHeight: Int
    let xOffset: Int, yOffset: Int
    let z: Int
}

struct GridView {
    let width: Int
    let height: Int
    let cells: UnsafeBufferPointer<HxCell>
    let glyphs: UnsafeBufferPointer<UInt8>
    let cursor: (x: Int, y: Int, visible: Bool, shape: UInt8)
    let revision: UInt64
    let panes: [PaneView]
    let placements: [Placement]

    /// The grapheme cluster for a cell, decoded from the side buffer.
    func glyph(_ cell: HxCell) -> String {
        guard cell.glyph_len > 0, let base = glyphs.baseAddress else { return " " }
        let bytes = UnsafeBufferPointer(
            start: base + Int(cell.glyph_off), count: Int(cell.glyph_len))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One machine the client is attached to.
struct EndpointInfo {
    enum Status { case connecting, online, offline }

    let index: Int
    let id: String
    let label: String
    let status: Status
    let isRemote: Bool
    /// Why it is not connected, when it has said so.
    let error: String?
    /// Reachable, but with no herdr on it — a failure that has an answer.
    let needsInstall: Bool
    var snapshot: Snapshot?
}

/// Owns the connection to the herdr server.
///
/// The Rust core runs the socket on its own thread; this type is the polling
/// face of it. All calls must come from the main thread.
final class HerdrSession {
    private var handle: OpaquePointer?
    private(set) var lastSnapshot: Snapshot?
    /// Callbacks awaiting a reply, keyed by request id.
    private var pendingReplies: [String: (String) -> Void] = [:]
    /// The latest snapshot from each endpoint, keyed by index.
    private var snapshots: [Int: Snapshot] = [:]

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

    // MARK: - Endpoints

    var endpointCount: Int { handle.map { hx_endpoint_count($0) } ?? 0 }
    var activeEndpoint: Int { handle.map { hx_active_endpoint($0) } ?? 0 }

    /// Every attached machine, with whatever snapshot it has sent so far.
    var endpoints: [EndpointInfo] {
        guard let handle else { return [] }
        return (0..<hx_endpoint_count(handle)).map { index in
            EndpointInfo(
                index: index,
                id: Self.take(hx_endpoint_id(handle, index)) ?? "",
                label: Self.take(hx_endpoint_label(handle, index)) ?? "",
                status: {
                    switch hx_endpoint_status(handle, index) {
                    case UInt8(HX_ENDPOINT_ONLINE): return .online
                    case UInt8(HX_ENDPOINT_OFFLINE): return .offline
                    default: return .connecting
                    }
                }(),
                isRemote: hx_endpoint_is_remote(handle, index),
                error: Self.take(hx_endpoint_error(handle, index)),
                needsInstall: hx_endpoint_needs_install(handle, index),
                snapshot: snapshots[index])
        }
    }

    /// The server boot an endpoint is on, which its commands must carry.
    func bootID(forEndpoint index: Int) -> String? {
        snapshots[index]?.bootID
    }

    @discardableResult
    func setActiveEndpoint(_ index: Int) -> Bool {
        guard let handle else { return false }
        return hx_set_active_endpoint(handle, index)
    }

    /// Picks up new snapshots from every endpoint, not only the active one:
    /// the sidebar shows remote agent status, which is the point of attaching
    /// to machines you are not currently looking at.
    ///
    /// Returns true when anything changed.
    @discardableResult
    func pollEndpointSnapshots() -> Bool {
        guard let handle else { return false }
        var changed = false
        let decoder = JSONDecoder()
        for index in 0..<hx_endpoint_count(handle) {
            guard let json = Self.take(hx_endpoint_snapshot_json(handle, index)),
                let data = json.data(using: .utf8),
                let snapshot = try? decoder.decode(Snapshot.self, from: data)
            else { continue }
            snapshots[index] = snapshot
            if index == hx_active_endpoint(handle) { lastSnapshot = snapshot }
            changed = true
        }
        return changed
    }

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
                alternateScreen: p.alternate_screen,
                mouseReporting: p.mouse_reporting,
                scrollOffsetFromBottom: p.scroll_offset_from_bottom,
                scrollMaxOffsetFromBottom: p.scroll_max_offset_from_bottom,
                contentRevision: p.content_revision)
        }

        return body(
            GridView(
                width: Int(raw.width),
                height: Int(raw.height),
                cells: UnsafeBufferPointer(start: raw.cells, count: raw.cell_count),
                glyphs: UnsafeBufferPointer(start: raw.glyphs, count: raw.glyph_bytes),
                cursor: (Int(raw.cursor_x), Int(raw.cursor_y), raw.cursor_visible, raw.cursor_shape),
                revision: raw.revision,
                panes: panes,
                placements: (0..<raw.placement_count).map { i in
                    let p = raw.placements[i]
                    return Placement(
                        assetID: p.asset_id,
                        x: Int(p.x), y: Int(p.y),
                        cols: Int(p.cols), rows: Int(p.rows),
                        sourceX: Int(p.source_x), sourceY: Int(p.source_y),
                        sourceWidth: Int(p.source_width), sourceHeight: Int(p.source_height),
                        xOffset: Int(p.x_offset), yOffset: Int(p.y_offset),
                        z: Int(p.z))
                }))
    }

    /// Decodes an image asset, or nil if the server has retired it.
    func image(for assetID: UInt64) -> CGImage? {
        guard let handle else { return nil }
        var asset = HxAsset()
        guard hx_asset(handle, assetID, &asset), let bytes = asset.data, asset.len > 0 else {
            return nil
        }
        let data = Data(bytes: bytes, count: asset.len)
        return ImageDecoder.decode(
            data: data,
            width: Int(asset.width),
            height: Int(asset.height),
            format: asset.format)
    }

    /// Drains queued server events, oldest first.
    ///
    /// Replies with a registered callback are delivered to it and left out of
    /// the returned events, so a caller awaiting one does not have to filter
    /// every unrelated reply back out.
    func drainEvents() -> [ServerEvent] {
        guard let handle else { return [] }
        var events: [ServerEvent] = []
        let decoder = JSONDecoder()
        var queue: [String] = []
        for index in 0..<hx_endpoint_count(handle) {
            while let json = Self.take(hx_next_endpoint_event(handle, index)) {
                queue.append(json)
            }
        }
        for json in queue {
            guard let data = json.data(using: .utf8),
                let event = try? decoder.decode(ServerEvent.self, from: data)
            else { continue }

            if case .response(let requestID, let body) = event,
                let reply = pendingReplies.removeValue(forKey: requestID)
            {
                reply(body)
                continue
            }
            events.append(event)
        }
        return events
    }

    func send(key: UInt16, codepoint: UInt32 = 0, modifiers: UInt8 = 0, to pane: String) {
        guard let handle else { return }
        _ = pane.withCString { hx_send_key(handle, $0, key, codepoint, modifiers) }
    }

    func send(text: String, to pane: String) {
        guard let handle else { return }
        _ = pane.withCString { p in text.withCString { t in hx_send_text(handle, p, t) } }
    }

    func send(paste text: String, to pane: String) {
        guard let handle else { return }
        _ = pane.withCString { p in text.withCString { t in hx_send_paste(handle, p, t) } }
    }

    func send(mouse: HxMouseEvent, to pane: String) {
        guard let handle else { return }
        var event = mouse
        _ = pane.withCString { hx_send_mouse(handle, $0, &event) }
    }

    func setDefaultColor(foreground: Bool, rgb: (UInt8, UInt8, UInt8)) {
        guard let handle else { return }
        _ = hx_set_default_color(handle, foreground, rgb.0, rgb.1, rgb.2)
    }

    func setAppearance(dark: Bool) {
        guard let handle else { return }
        _ = hx_set_appearance(handle, dark)
    }

    func setPalette(_ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        _ = bytes.withUnsafeBufferPointer { hx_set_palette(handle, $0.baseAddress, bytes.count / 3) }
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard let handle else { return }
        _ = hx_resize(handle, UInt16(cols), UInt16(rows), UInt32(cellWidth), UInt32(cellHeight))
    }

    /// Invokes one of herdr's 38 endpoint methods.
    ///
    /// `onReply` is called once with the raw reply body. A request whose reply
    /// never arrives — a server that went away mid-flight — simply leaves the
    /// callback unused; it is dropped when the session is.
    func request(_ json: String, bootID: String, id: String? = nil, onReply: ((String) -> Void)? = nil) {
        guard let handle else { return }
        if let id, let onReply { pendingReplies[id] = onReply }
        _ = bootID.withCString { b in json.withCString { r in hx_endpoint_request(handle, b, r) } }
    }

    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { hx_string_free(pointer) }
        return String(cString: pointer)
    }
}

/// The SSH machines herdr will attach to.
///
/// Read and written straight from herdr's own catalog rather than through the
/// session: a machine that is disabled, or that failed to connect, still has to
/// be listed and edited, and there is no endpoint method for any of this — the
/// catalog is a client-side file that herdr's own TUI edits the same way.
enum Machines {
    struct Machine: Codable, Identifiable, Equatable {
        var id: String
        var label: String
        var target: String
        var session: String
        var enabled: Bool
    }

    static func all() -> [Machine] {
        guard let json = HerdrSession.take(hx_machines_json()),
            let data = json.data(using: .utf8),
            let machines = try? JSONDecoder().decode([Machine].self, from: data)
        else { return [] }
        return machines
    }

    /// Why a save was refused, in the words herdr's own rules use.
    struct Refusal: Error {
        let reason: String
    }

    /// Returns the saved id, or the reason it was refused.
    @discardableResult
    static func save(
        id: String?, label: String, target: String, session: String, enabled: Bool
    ) -> Result<String, Refusal> {
        let saved = label.withCString { l in
            target.withCString { t in
                session.withCString { s in
                    if let id {
                        return id.withCString { hx_machine_save($0, l, t, s, enabled) }
                    }
                    return hx_machine_save(nil, l, t, s, enabled)
                }
            }
        }
        if let saved = HerdrSession.take(saved) { return .success(saved) }
        return .failure(Refusal(reason: HerdrSession.take(hx_machine_error()) ?? "could not save"))
    }

    @discardableResult
    static func remove(id: String) -> Bool {
        id.withCString { hx_machine_remove($0) }
    }
}
