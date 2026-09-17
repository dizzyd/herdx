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
use crate::protocol::{CellData, ClientMessage, ServerMessage};

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
struct Grid {
    width: u16,
    height: u16,
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
    fn ingest_panes(&mut self, panes: &[crate::protocol::PaneSurfacePane]) {
        self.panes.clear();
        self.pane_ids.clear();
        for pane in panes {
            self.panes.push(HxPane {
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
                id_index: self.pane_ids.len() as u32,
            });
            self.pane_ids.push(pane.pane_id.clone());
        }
    }

    fn ingest(&mut self, width: u16, height: u16, cells: &[CellData], revision: u64) {
        self.width = width;
        self.height = height;
        self.revision = revision;
        self.cells.clear();
        self.glyphs.clear();
        for cell in cells {
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
                    if crate::protocol::write_message(&mut writer, &message).is_err() {
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
                let mut grid = loop_shared.grid.lock().unwrap();
                grid.ingest(
                    frame.frame.width,
                    frame.frame.height,
                    &frame.frame.cells,
                    frame.surface_revision,
                );
                grid.ingest_panes(&frame.panes);
                if let Some(cursor) = &frame.frame.cursor {
                    grid.cursor_x = cursor.x;
                    grid.cursor_y = cursor.y;
                    grid.cursor_visible = cursor.visible;
                    grid.cursor_shape = cursor.shape;
                } else {
                    grid.cursor_visible = false;
                }
            }
            Ok(ServerMessage::EndpointControl { kind, data })
                if kind == crate::protocol::endpoint::ENDPOINT_SNAPSHOT_KIND =>
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

fn key_code(kind: u16, codepoint: u32) -> Option<crate::protocol::ClientKeyCode> {
    use crate::protocol::ClientKeyCode as K;
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
            events: vec![crate::protocol::ClientPaneInputEvent::Key {
                code,
                modifiers,
                kind: crate::protocol::ClientKeyKind::Press,
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
            events: vec![crate::protocol::ClientPaneInputEvent::TextCommit(
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
            surface_size: crate::protocol::ClientSurfaceSize { cols, rows },
            pixel_mouse: true,
        })
        .is_ok()
}
