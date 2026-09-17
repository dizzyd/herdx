//! C ABI over the endpoint client, for the Swift app.
//!
//! The connection runs on its own thread and keeps the latest snapshot and a
//! flattened copy of the current surface behind a mutex. Swift polls once per
//! frame and reads the grid as contiguous memory, so no per-cell FFI calls
//! happen on the render path.

use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// Connect failures happen before a session exists, so they park here.
static LAST_CONNECT_ERROR_CELL: OnceLock<Mutex<Option<String>>> = OnceLock::new();
#[allow(non_snake_case)]
fn LAST_CONNECT_ERROR() -> &'static Mutex<Option<String>> {
    LAST_CONNECT_ERROR_CELL.get_or_init(|| Mutex::new(None))
}

use crate::client::{default_socket_path, hello, EndpointConnection};
use herdr_protocol::protocol::{
    CellData, ClientMessage, PaneSurfaceFrame, PaneSurfacePatch, ServerMessage,
};

/// One terminal cell, laid out for direct consumption by the renderer.
///
/// Glyphs are variable-length grapheme clusters, so they live in a side buffer
/// (`HxGrid.glyphs`) and each cell carries an offset/length into it.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxCell {
    /// Packed herdr color: 0x00=named, 0x01=indexed, 0x02=RGB.
    pub fg: u32,
    pub bg: u32,
    /// ratatui modifier bits plus herdr's underline-style extension.
    pub modifier: u16,
    pub glyph_len: u16,
    pub glyph_off: u32,
}

/// One pane's placement inside the shared surface, in cell units.
///
/// The renderer draws a single grid today, but routes every cell span through
/// the owning pane. That keeps the seam open for promoting panes to real
/// `NSView`s without reworking patch delivery.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxPane {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    /// Content area, excluding any border the server drew.
    pub inner_x: u16,
    pub inner_y: u16,
    pub inner_width: u16,
    pub inner_height: u16,
    pub focused: bool,
    pub alternate_screen: bool,
    /// Index into the session's pane-id table; use `hx_pane_id`.
    pub id_index: u32,
}

/// A flattened pane surface: `width * height` cells in row-major order.
#[repr(C)]
pub struct HxGrid {
    pub width: u16,
    pub height: u16,
    pub cells: *const HxCell,
    pub cell_count: usize,
    pub glyphs: *const u8,
    pub glyph_bytes: usize,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub cursor_shape: u8,
    /// Bumped on every committed surface so the renderer can skip idle frames.
    pub revision: u64,
    pub panes: *const HxPane,
    pub pane_count: usize,
}

#[derive(Default, Clone)]
pub(crate) struct Grid {
    width: u16,
    height: u16,
    /// The authoritative cells. Patches arrive as sparse row spans against the
    /// last committed surface, so the full grid has to be kept to apply them;
    /// `cells`/`glyphs` below are just a flattened view of this.
    source: Vec<CellData>,
    cells: Vec<HxCell>,
    glyphs: Vec<u8>,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    revision: u64,
    panes: Vec<HxPane>,
    pane_ids: Vec<String>,
}

impl Grid {
    /// Installs a complete surface, replacing whatever came before.
    fn replace(&mut self, frame: &PaneSurfaceFrame) {
        self.width = frame.frame.width;
        self.height = frame.frame.height;
        self.source = frame.frame.cells.clone();
        self.revision = frame.surface_revision;
        self.set_cursor(frame.frame.cursor.as_ref());
        self.replace_panes(&frame.panes);
        self.flatten();
    }

    /// Applies one incremental patch.
    ///
    /// Returns false when the patch does not build on the surface we hold. That
    /// happens after a dropped or reordered frame; the caller leaves the last
    /// good surface on screen until the server sends a complete one, which is
    /// better than rendering a grid stitched from mismatched revisions.
    fn apply_patch(&mut self, patch: &PaneSurfacePatch) -> bool {
        if self.source.is_empty() || patch.base_surface_revision != self.revision {
            return false;
        }
        let width = usize::from(self.width);
        for row in &patch.rows {
            let start = usize::from(row.y) * width + usize::from(row.x);
            let Some(slice) = self.source.get_mut(start..start + row.cells.len()) else {
                // A span outside the grid means we are out of sync with the
                // server's idea of the surface size; force a full redraw.
                return false;
            };
            slice.clone_from_slice(&row.cells);
        }
        self.merge_panes(&patch.panes);
        if patch.cursor.is_some() {
            self.set_cursor(patch.cursor.as_ref());
        }
        self.revision = patch.surface_revision;
        self.flatten();
        true
    }

    fn set_cursor(&mut self, cursor: Option<&herdr_protocol::protocol::CursorState>) {
        match cursor {
            Some(cursor) => {
                self.cursor_x = cursor.x;
                self.cursor_y = cursor.y;
                self.cursor_visible = cursor.visible;
                self.cursor_shape = cursor.shape;
            }
            None => self.cursor_visible = false,
        }
    }

    fn replace_panes(&mut self, panes: &[herdr_protocol::protocol::PaneSurfacePane]) {
        self.panes.clear();
        self.pane_ids.clear();
        for pane in panes {
            let id_index = self.pane_ids.len() as u32;
            self.pane_ids.push(pane.pane_id.clone());
            self.panes.push(Self::pane(pane, id_index));
        }
    }

    /// A patch carries metadata only for panes whose content changed, so these
    /// update matching entries in place rather than replacing the set.
    fn merge_panes(&mut self, panes: &[herdr_protocol::protocol::PaneSurfacePane]) {
        for pane in panes {
            if let Some(index) = self.pane_ids.iter().position(|id| *id == pane.pane_id) {
                let id_index = self.panes[index].id_index;
                self.panes[index] = Self::pane(pane, id_index);
            }
        }
    }

    fn pane(pane: &herdr_protocol::protocol::PaneSurfacePane, id_index: u32) -> HxPane {
        HxPane {
            x: pane.rect.x,
            y: pane.rect.y,
            width: pane.rect.width,
            height: pane.rect.height,
            inner_x: pane.inner_rect.x,
            inner_y: pane.inner_rect.y,
            inner_width: pane.inner_rect.width,
            inner_height: pane.inner_rect.height,
            focused: pane.focused,
            alternate_screen: pane.alternate_screen_active,
            id_index,
        }
    }

    /// Packs the cells into the flat form the renderer reads.
    fn flatten(&mut self) {
        self.cells.clear();
        self.glyphs.clear();
        self.cells.reserve(self.source.len());
        for cell in &self.source {
            let bytes = cell.symbol.as_bytes();
            let off = self.glyphs.len() as u32;
            self.glyphs.extend_from_slice(bytes);
            self.cells.push(HxCell {
                fg: cell.fg,
                bg: cell.bg,
                modifier: cell.modifier,
                glyph_len: bytes.len() as u16,
                glyph_off: off,
            });
        }
    }
}

struct Shared {
    grid: Mutex<Grid>,
    snapshot_json: Mutex<Option<String>>,
    error: Mutex<Option<String>>,
    connected: AtomicBool,
}

pub struct HxSession {
    shared: Arc<Shared>,
    /// Render-thread-private copy. `hx_grid_acquire` refreshes it from the
    /// receive thread's buffer, so pointers handed to the caller stay valid
    /// without holding a lock across the FFI boundary.
    front: Grid,
    outbound: std::sync::mpsc::Sender<ClientMessage>,
}

/// Connects to the running herdr server and starts the receive loop.
///
/// Returns null on failure; call `hx_last_error` for the reason.
///
/// # Safety
/// The returned pointer must be released with `hx_session_free`.
#[no_mangle]
pub unsafe extern "C" fn hx_session_connect(
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
) -> *mut HxSession {
    let shared = Arc::new(Shared {
        grid: Mutex::new(Grid::default()),
        snapshot_json: Mutex::new(None),
        error: Mutex::new(None),
        connected: AtomicBool::new(false),
    });

    let path = default_socket_path();
    let mut conn =
        match EndpointConnection::connect(&path, &hello(cols, rows, cell_width_px, cell_height_px))
        {
            Ok(conn) => conn,
            Err(err) => {
                *LAST_CONNECT_ERROR().lock().unwrap() = Some(format!("{err}"));
                return std::ptr::null_mut();
            }
        };

    if let Some(note) = conn.version_note() {
        *shared.error.lock().unwrap() = Some(note);
    }
    shared.connected.store(true, Ordering::Release);

    let (tx, rx) = std::sync::mpsc::channel::<ClientMessage>();
    match conn.try_clone_writer() {
        Ok(mut writer) => {
            std::thread::spawn(move || {
                for message in rx {
                    if herdr_protocol::protocol::write_message(&mut writer, &message).is_err() {
                        return;
                    }
                }
            });
        }
        Err(err) => {
            *LAST_CONNECT_ERROR().lock().unwrap() = Some(format!("{err}"));
            return std::ptr::null_mut();
        }
    }

    let loop_shared = Arc::clone(&shared);
    std::thread::spawn(move || loop {
        match conn.recv() {
            Ok(ServerMessage::PaneSurface(frame)) => {
                loop_shared.grid.lock().unwrap().replace(&frame);
            }
            Ok(ServerMessage::PaneSurfacePatch(patch)) => {
                let mut grid = loop_shared.grid.lock().unwrap();
                if !grid.apply_patch(&patch) {
                    // Keep the last coherent surface rather than a stitched
                    // one, and wait for the server's next complete frame.
                    let held = grid.revision;
                    drop(grid);
                    *loop_shared.error.lock().unwrap() = Some(format!(
                        "ignored surface patch {} built on revision {}; holding revision {held}",
                        patch.surface_revision, patch.base_surface_revision
                    ));
                }
            }
            Ok(ServerMessage::EndpointControl { kind, data })
                if kind == herdr_protocol::protocol::endpoint::ENDPOINT_SNAPSHOT_KIND =>
            {
                *loop_shared.snapshot_json.lock().unwrap() = Some(data);
            }
            Ok(_) => {}
            Err(err) => {
                *loop_shared.error.lock().unwrap() = Some(format!("{err}"));
                loop_shared.connected.store(false, Ordering::Release);
                return;
            }
        }
    });

    Box::into_raw(Box::new(HxSession {
        shared,
        front: Grid::default(),
        outbound: tx,
    }))
}

/// Why the most recent `hx_session_connect` failed. Caller frees with
/// `hx_string_free`.
#[no_mangle]
pub extern "C" fn hx_connect_error() -> *mut c_char {
    match LAST_CONNECT_ERROR()
        .lock()
        .unwrap()
        .take()
        .and_then(|s| CString::new(s).ok())
    {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `session` must come from `hx_session_connect` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn hx_session_free(session: *mut HxSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

/// # Safety
/// `session` must be a live session pointer.
#[no_mangle]
pub unsafe extern "C" fn hx_session_connected(session: *const HxSession) -> bool {
    session
        .as_ref()
        .is_some_and(|s| s.shared.connected.load(Ordering::Acquire))
}

/// Refreshes the caller's grid view from the receive thread.
///
/// Returns false when no surface has arrived yet. The pointers written to `out`
/// reference session-owned memory and stay valid until the next call on this
/// session, so the caller must not retain them across frames.
///
/// # Safety
/// `session` must be a live session pointer, used from one thread at a time.
#[no_mangle]
pub unsafe extern "C" fn hx_grid_acquire(session: *mut HxSession, out: *mut HxGrid) -> bool {
    let Some(session) = session.as_mut() else {
        return false;
    };
    {
        let back = session.shared.grid.lock().unwrap();
        if back.cells.is_empty() {
            return false;
        }
        if back.revision != session.front.revision || session.front.cells.is_empty() {
            session.front.clone_from(&back);
        }
    }
    let front = &session.front;
    std::ptr::write(
        out,
        HxGrid {
            width: front.width,
            height: front.height,
            cells: front.cells.as_ptr(),
            cell_count: front.cells.len(),
            glyphs: front.glyphs.as_ptr(),
            glyph_bytes: front.glyphs.len(),
            cursor_x: front.cursor_x,
            cursor_y: front.cursor_y,
            cursor_visible: front.cursor_visible,
            cursor_shape: front.cursor_shape,
            revision: front.revision,
            panes: front.panes.as_ptr(),
            pane_count: front.panes.len(),
        },
    );
    true
}

/// The pane id for `HxPane.id_index`. Caller frees with `hx_string_free`.
///
/// # Safety
/// `session` must be live and previously refreshed by `hx_grid_acquire`.
#[no_mangle]
pub unsafe extern "C" fn hx_pane_id(session: *const HxSession, id_index: u32) -> *mut c_char {
    let Some(session) = session.as_ref() else {
        return std::ptr::null_mut();
    };
    match session
        .front
        .pane_ids
        .get(id_index as usize)
        .and_then(|s| CString::new(s.as_str()).ok())
    {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Returns the latest snapshot as JSON, or null. Caller frees with `hx_string_free`.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_take_snapshot_json(session: *const HxSession) -> *mut c_char {
    let Some(session) = session.as_ref() else {
        return std::ptr::null_mut();
    };
    let taken = session.shared.snapshot_json.lock().unwrap().take();
    match taken.and_then(|s| CString::new(s).ok()) {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_last_error(session: *const HxSession) -> *mut c_char {
    let Some(session) = session.as_ref() else {
        return std::ptr::null_mut();
    };
    let taken = session.shared.error.lock().unwrap().take();
    match taken.and_then(|s| CString::new(s).ok()) {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `s` must come from this library.
#[no_mangle]
pub unsafe extern "C" fn hx_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Sends one endpoint request (a JSON-RPC-shaped call, see herdr's 38 methods).
///
/// # Safety
/// `session` must be live and `boot_id`/`request` valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_request(
    session: *const HxSession,
    boot_id: *const c_char,
    request: *const c_char,
) -> bool {
    let (Some(session), false, false) = (session.as_ref(), boot_id.is_null(), request.is_null())
    else {
        return false;
    };
    let (Ok(boot_id), Ok(request)) = (
        CStr::from_ptr(boot_id).to_str(),
        CStr::from_ptr(request).to_str(),
    ) else {
        return false;
    };
    session
        .outbound
        .send(ClientMessage::ClientShellEndpointRequest {
            boot_id: boot_id.to_owned(),
            request: request.to_owned(),
        })
        .is_ok()
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// Key codes the Swift layer maps `NSEvent` onto.
///
/// These mirror `ClientKeyCode`. Anything printable travels as `HX_KEY_CHAR`
/// plus a codepoint, so the server can encode it for the pane's negotiated
/// keyboard protocol.
pub const HX_KEY_CHAR: u16 = 0;
pub const HX_KEY_BACKSPACE: u16 = 1;
pub const HX_KEY_ENTER: u16 = 2;
pub const HX_KEY_LEFT: u16 = 3;
pub const HX_KEY_RIGHT: u16 = 4;
pub const HX_KEY_UP: u16 = 5;
pub const HX_KEY_DOWN: u16 = 6;
pub const HX_KEY_HOME: u16 = 7;
pub const HX_KEY_END: u16 = 8;
pub const HX_KEY_PAGEUP: u16 = 9;
pub const HX_KEY_PAGEDOWN: u16 = 10;
pub const HX_KEY_TAB: u16 = 11;
pub const HX_KEY_BACKTAB: u16 = 12;
pub const HX_KEY_DELETE: u16 = 13;
pub const HX_KEY_INSERT: u16 = 14;
pub const HX_KEY_ESC: u16 = 15;
pub const HX_KEY_F1: u16 = 16;

fn key_code(kind: u16, codepoint: u32) -> Option<herdr_protocol::protocol::ClientKeyCode> {
    use herdr_protocol::protocol::ClientKeyCode as K;
    Some(match kind {
        HX_KEY_CHAR => K::Char(char::from_u32(codepoint)?),
        HX_KEY_BACKSPACE => K::Backspace,
        HX_KEY_ENTER => K::Enter,
        HX_KEY_LEFT => K::Left,
        HX_KEY_RIGHT => K::Right,
        HX_KEY_UP => K::Up,
        HX_KEY_DOWN => K::Down,
        HX_KEY_HOME => K::Home,
        HX_KEY_END => K::End,
        HX_KEY_PAGEUP => K::PageUp,
        HX_KEY_PAGEDOWN => K::PageDown,
        HX_KEY_TAB => K::Tab,
        HX_KEY_BACKTAB => K::BackTab,
        HX_KEY_DELETE => K::Delete,
        HX_KEY_INSERT => K::Insert,
        HX_KEY_ESC => K::Esc,
        n if n >= HX_KEY_F1 => K::F((n - HX_KEY_F1 + 1) as u8),
        _ => return None,
    })
}

/// Sends one key press to a pane as a semantic event.
///
/// `modifiers` uses crossterm's bits: shift 1, control 2, alt 4, super 8.
///
/// # Safety
/// `session` must be live and `pane_id` valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_send_key(
    session: *const HxSession,
    pane_id: *const c_char,
    kind: u16,
    codepoint: u32,
    modifiers: u8,
) -> bool {
    let (Some(session), false) = (session.as_ref(), pane_id.is_null()) else {
        return false;
    };
    let Ok(pane_id) = CStr::from_ptr(pane_id).to_str() else {
        return false;
    };
    let Some(code) = key_code(kind, codepoint) else {
        return false;
    };
    session
        .outbound
        .send(ClientMessage::ClientShellPaneInput {
            pane_id: pane_id.to_owned(),
            events: vec![herdr_protocol::protocol::ClientPaneInputEvent::Key {
                code,
                modifiers,
                kind: herdr_protocol::protocol::ClientKeyKind::Press,
                repeat_count: 1,
                shifted_codepoint: None,
                generated_text: None,
                // Release tracking is only meaningful with a physical key
                // identity, which NSEvent does not give us here.
                tracks_release: false,
                physical_key_id: None,
                windows_record: None,
            }],
        })
        .is_ok()
}

/// Sends committed text (IME output, paste) to a pane.
///
/// # Safety
/// `session` must be live and both strings valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_send_text(
    session: *const HxSession,
    pane_id: *const c_char,
    text: *const c_char,
) -> bool {
    let (Some(session), false, false) = (session.as_ref(), pane_id.is_null(), text.is_null()) else {
        return false;
    };
    let (Ok(pane_id), Ok(text)) = (
        CStr::from_ptr(pane_id).to_str(),
        CStr::from_ptr(text).to_str(),
    ) else {
        return false;
    };
    session
        .outbound
        .send(ClientMessage::ClientShellPaneInput {
            pane_id: pane_id.to_owned(),
            events: vec![herdr_protocol::protocol::ClientPaneInputEvent::TextCommit(
                text.to_owned(),
            )],
        })
        .is_ok()
}

/// Tells the server the surface size changed.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_resize(
    session: *const HxSession,
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
) -> bool {
    let Some(session) = session.as_ref() else {
        return false;
    };
    session
        .outbound
        .send(ClientMessage::ClientShellResize {
            cell_width_px,
            cell_height_px,
            surface_size: herdr_protocol::protocol::ClientSurfaceSize { cols, rows },
            pixel_mouse: true,
        })
        .is_ok()
}


#[cfg(test)]
mod tests {
    use super::*;
    use herdr_protocol::protocol::{
        CursorState, FrameData, PaneSurfacePatchRow, PaneSurfaceScrollMetrics, SurfaceRect,
    };

    fn cell(symbol: &str) -> CellData {
        CellData {
            symbol: symbol.to_owned(),
            fg: 0x0200_0000,
            bg: 0,
            modifier: 0,
            skip: false,
            hyperlink: None,
        }
    }

    fn pane(id: &str) -> herdr_protocol::protocol::PaneSurfacePane {
        herdr_protocol::protocol::PaneSurfacePane {
            pane_id: id.to_owned(),
            content_revision: 1,
            rect: SurfaceRect { x: 0, y: 0, width: 3, height: 2 },
            inner_rect: SurfaceRect { x: 0, y: 0, width: 3, height: 2 },
            scrollbar_rect: None,
            scroll: Some(PaneSurfaceScrollMetrics {
                offset_from_bottom: 0,
                max_offset_from_bottom: 0,
                viewport_rows: 2,
            }),
            focused: true,
            mouse_reporting: false,
            sgr_pixel_mouse: false,
            alternate_screen_active: false,
            pixel_width: 24,
            pixel_height: 32,
        }
    }

    /// A 3x2 surface reading "abc" / "def".
    fn surface(revision: u64) -> PaneSurfaceFrame {
        PaneSurfaceFrame {
            boot_id: "boot".into(),
            projection_revision: 1,
            surface_revision: revision,
            frame: FrameData {
                cells: ["a", "b", "c", "d", "e", "f"].iter().map(|s| cell(s)).collect(),
                width: 3,
                height: 2,
                cursor: Some(CursorState { x: 1, y: 0, visible: true, shape: 2 }),
                hyperlinks: Vec::new(),
                graphics: Vec::new(),
            },
            panes: vec![pane("p1")],
            splits: Vec::new(),
            popup: None,
            graphics: Default::default(),
        }
    }

    fn patch(base: u64, revision: u64, rows: Vec<PaneSurfacePatchRow>) -> PaneSurfacePatch {
        PaneSurfacePatch {
            boot_id: "boot".into(),
            projection_revision: 1,
            base_surface_revision: base,
            surface_revision: revision,
            rows,
            panes: Vec::new(),
            cursor: None,
        }
    }

    fn text(grid: &Grid) -> String {
        grid.source.iter().map(|c| c.symbol.as_str()).collect()
    }

    #[test]
    fn full_surface_populates_the_flattened_view() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));

        assert_eq!(text(&grid), "abcdef");
        assert_eq!(grid.cells.len(), 6);
        assert_eq!(grid.pane_ids, vec!["p1".to_string()]);
        assert!(grid.cursor_visible);
        assert_eq!((grid.cursor_x, grid.cursor_y, grid.cursor_shape), (1, 0, 2));
    }

    #[test]
    fn patch_updates_only_the_spans_it_carries() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));

        let applied = grid.apply_patch(&patch(
            1,
            2,
            vec![PaneSurfacePatchRow { x: 1, y: 1, cells: vec![cell("X"), cell("Y")] }],
        ));

        assert!(applied);
        assert_eq!(text(&grid), "abcdXY");
        assert_eq!(grid.revision, 2);
    }

    /// The flattened glyph buffer has to be rebuilt after a patch, or the
    /// renderer keeps drawing the old text from stale offsets.
    #[test]
    fn patch_rebuilds_the_flattened_glyphs() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));
        grid.apply_patch(&patch(
            1,
            2,
            vec![PaneSurfacePatchRow { x: 0, y: 0, cells: vec![cell("Z")] }],
        ));

        let first = &grid.cells[0];
        let bytes = &grid.glyphs
            [first.glyph_off as usize..first.glyph_off as usize + first.glyph_len as usize];
        assert_eq!(std::str::from_utf8(bytes).unwrap(), "Z");
    }

    #[test]
    fn patch_against_a_different_revision_is_refused() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));

        let applied = grid.apply_patch(&patch(
            7,
            8,
            vec![PaneSurfacePatchRow { x: 0, y: 0, cells: vec![cell("X")] }],
        ));

        assert!(!applied, "a patch built on another surface must not be applied");
        assert_eq!(text(&grid), "abcdef", "the last good surface must survive");
        assert_eq!(grid.revision, 1);
    }

    /// A span reaching past the grid means we disagree with the server about
    /// the surface size; better to hold than to panic or corrupt the view.
    #[test]
    fn out_of_bounds_span_is_refused_without_panicking() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));

        let applied = grid.apply_patch(&patch(
            1,
            2,
            vec![PaneSurfacePatchRow {
                x: 2,
                y: 1,
                cells: vec![cell("X"), cell("Y"), cell("Z")],
            }],
        ));

        assert!(!applied);
        assert_eq!(grid.revision, 1);
    }

    #[test]
    fn patch_pane_metadata_merges_in_place() {
        let mut grid = Grid::default();
        grid.replace(&surface(1));

        let mut updated = pane("p1");
        updated.focused = false;
        updated.alternate_screen_active = true;
        let mut p = patch(1, 2, Vec::new());
        p.panes = vec![updated];
        assert!(grid.apply_patch(&p));

        assert_eq!(grid.panes.len(), 1, "a patch must not duplicate panes");
        assert!(!grid.panes[0].focused);
        assert!(grid.panes[0].alternate_screen);
        assert_eq!(grid.pane_ids, vec!["p1".to_string()]);
    }
}
