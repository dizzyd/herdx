//! C ABI over the endpoint client, for the Swift app.
//!
//! The connection runs on its own thread and keeps the latest snapshot and a
//! flattened copy of the current surface behind a mutex. Swift polls once per
//! frame and reads the grid as contiguous memory, so no per-cell FFI calls
//! happen on the render path.

use std::ffi::{c_char, CStr, CString};
use std::io::Write as _;
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
    /// True while the pane's program asked for mouse reporting, in which case
    /// drags belong to it rather than to text selection.
    pub mouse_reporting: bool,
    /// Scrollback position, for turning a viewport row into the absolute row
    /// `pane.selection.read` expects.
    pub scroll_offset_from_bottom: u64,
    pub scroll_max_offset_from_bottom: u64,
    /// Identifies the content a selection was taken against.
    pub content_revision: u64,
    /// Index into the session's pane-id table; use `hx_pane_id`.
    pub id_index: u32,
}

/// One image placement, in surface cell coordinates.
///
/// The server sends the complete desired scene each frame, already clipped, so
/// the renderer just draws these; there is no placement state to track.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxPlacement {
    /// Stable id for the image bytes; resolve with `hx_asset`.
    pub asset_id: u64,
    pub x: u16,
    pub y: u16,
    pub cols: u32,
    pub rows: u32,
    /// The crop of the source image this placement shows.
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
    /// Sub-cell nudge, in pixels.
    pub x_offset: u32,
    pub y_offset: u32,
    pub z: i32,
}

pub const HX_IMAGE_RGB: u8 = 0;
pub const HX_IMAGE_RGBA: u8 = 1;
pub const HX_IMAGE_PNG: u8 = 2;

/// Decoded image bytes held by the session.
#[repr(C)]
pub struct HxAsset {
    pub width: u32,
    pub height: u32,
    pub format: u8,
    pub data: *const u8,
    pub len: usize,
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
    pub placements: *const HxPlacement,
    pub placement_count: usize,
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
    placements: Vec<HxPlacement>,
}

/// Image bytes the server has sent us, kept until nothing refers to them.
///
/// Assets arrive only once per scene — the server tracks what this connection
/// already has — so dropping them early would leave images blank with no way to
/// ask for them again.
#[derive(Default)]
struct AssetCache {
    by_key: std::collections::HashMap<
        herdr_protocol::protocol::SurfaceGraphicsAssetKey,
        u64,
    >,
    assets: std::collections::HashMap<u64, herdr_protocol::protocol::SurfaceGraphicsAsset>,
    next_id: u64,
}

impl AssetCache {
    fn ingest(&mut self, scene: &herdr_protocol::protocol::SurfaceGraphicsScene) -> Vec<HxPlacement> {
        for asset in &scene.assets {
            let id = *self.by_key.entry(asset.key.clone()).or_insert_with(|| {
                self.next_id += 1;
                self.next_id
            });
            self.assets.entry(id).or_insert_with(|| asset.clone());
        }

        let placements: Vec<HxPlacement> = scene
            .placements
            .iter()
            .filter_map(|placement| {
                let asset_id = *self.by_key.get(&placement.asset)?;
                Some(HxPlacement {
                    asset_id,
                    x: placement.x,
                    y: placement.y,
                    cols: placement.cols,
                    rows: placement.rows,
                    source_x: placement.source_x,
                    source_y: placement.source_y,
                    source_width: placement.source_width,
                    source_height: placement.source_height,
                    x_offset: placement.x_offset,
                    y_offset: placement.y_offset,
                    z: placement.z,
                })
            })
            .collect();

        // Keep what the scene still draws plus what the server asked us to
        // retain; anything else will be resent if it comes back.
        let mut live: std::collections::HashSet<u64> =
            placements.iter().map(|p| p.asset_id).collect();
        for key in &scene.retained_assets {
            if let Some(id) = self.by_key.get(key) {
                live.insert(*id);
            }
        }
        self.assets.retain(|id, _| live.contains(id));
        self.by_key.retain(|_, id| live.contains(id));

        placements
    }
}

impl Grid {
    /// Installs a complete surface, replacing whatever came before.
    fn replace(&mut self, frame: &PaneSurfaceFrame, assets: &mut AssetCache) {
        self.width = frame.frame.width;
        self.height = frame.frame.height;
        self.source = frame.frame.cells.clone();
        self.revision = frame.surface_revision;
        self.set_cursor(frame.frame.cursor.as_ref());
        self.replace_panes(&frame.panes);
        self.placements = assets.ingest(&frame.graphics);
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
            mouse_reporting: pane.mouse_reporting,
            scroll_offset_from_bottom: pane.scroll.map_or(0, |s| s.offset_from_bottom),
            scroll_max_offset_from_bottom: pane.scroll.map_or(0, |s| s.max_offset_from_bottom),
            content_revision: pane.content_revision,
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

/// A discrete thing the server told us about, for the UI to present.
///
/// herdr deliberately reports *semantic* events and leaves presentation to each
/// client, so these stay close to the wire and let the Mac app decide whether
/// something becomes a notification, a sound, or nothing.
#[derive(serde::Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    /// An agent changed state in a way worth surfacing.
    Notification {
        kind: String,
        title: String,
        body: Option<String>,
        sound: Option<String>,
        agent: Option<String>,
        workspace_id: Option<String>,
        tab_id: Option<String>,
        pane_id: Option<String>,
    },
    /// OSC 52 from a program inside a pane.
    Clipboard { text: String },
    /// `None` restores the default title.
    WindowTitle { title: Option<String> },
    Bell { count: u16 },
    Error { message: String },
    /// A completed reply to one `hx_endpoint_request`.
    Response { request_id: String, body: String },
}

/// Just the field we need out of a snapshot, without parsing the rest.
#[derive(serde::Deserialize)]
struct SnapshotBootId {
    boot_id: String,
}

struct Shared {
    grid: Mutex<Grid>,
    /// The endpoint's current server boot.
    ///
    /// Endpoint commands carry it, and the server rejects one from an earlier
    /// boot with `stale_boot` — so it has to be learned from a snapshot before
    /// any command can be sent, and relearned when a server restarts.
    boot_id: Mutex<Option<String>>,
    /// Whether this endpoint should be rendering a surface, and whether the
    /// server has been told. They differ while a switch waits for a boot id.
    desired_surface: AtomicBool,
    applied_surface: AtomicBool,
    /// The surface size, so a resync can ask for the size we already have.
    geometry: Mutex<Geometry>,
    /// Set while a resync request is outstanding, so one refused patch does not
    /// produce a resize per frame.
    resync_pending: AtomicBool,
    snapshot_json: Mutex<Option<String>>,
    error: Mutex<Option<String>>,
    events: Mutex<std::collections::VecDeque<String>>,
    assets: Mutex<AssetCache>,
    connected: AtomicBool,
}

/// Reassembles endpoint replies, which arrive as ordered chunks per request.
#[derive(Default)]
struct PendingResponses(std::collections::HashMap<String, Vec<u8>>);

impl PendingResponses {
    fn push(&mut self, request_id: String, data: &[u8], final_chunk: bool) -> Option<(String, String)> {
        let buffer = self.0.entry(request_id.clone()).or_default();
        buffer.extend_from_slice(data);
        if !final_chunk {
            return None;
        }
        let bytes = self.0.remove(&request_id)?;
        Some((request_id, String::from_utf8_lossy(&bytes).into_owned()))
    }
}

impl Shared {
    fn push(&self, event: Event) {
        let Ok(json) = serde_json::to_string(&event) else {
            return;
        };
        let mut queue = self.events.lock().unwrap();
        // A UI that stops draining must not grow this without bound; dropping
        // the oldest keeps the most recent agent state visible.
        if queue.len() >= 256 {
            queue.pop_front();
        }
        queue.push_back(json);
    }
}

/// The surface geometry last negotiated with the server.
///
/// Mouse events carry it so panes running SGR pixel mouse (mode 1016) get exact
/// coordinates rather than cell-rounded ones.
#[derive(Clone, Copy)]
struct Geometry {
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
}

/// Connection state, mirroring what the sidebar needs to show.
pub const HX_ENDPOINT_CONNECTING: u8 = 0;
pub const HX_ENDPOINT_ONLINE: u8 = 1;
pub const HX_ENDPOINT_OFFLINE: u8 = 2;

/// One attached machine.
struct EndpointState {
    endpoint: crate::endpoint::Endpoint,
    shared: Arc<Shared>,
    /// Queued before the connection is up, so input is never lost to a race
    /// with a slow ssh handshake.
    outbound: std::sync::mpsc::Sender<ClientMessage>,
    status: Arc<std::sync::atomic::AtomicU8>,
}

pub struct HxSession {
    endpoints: Vec<EndpointState>,
    /// Which endpoint renders a surface and receives input.
    active: usize,
    /// The active endpoint's handles, so everything that works on "the current
    /// machine" does not have to resolve it each time.
    shared: Arc<Shared>,
    outbound: std::sync::mpsc::Sender<ClientMessage>,
    /// The window is one size, so geometry is shared: every endpoint is told
    /// about a resize, since any of them may become active.
    geometry: Mutex<Geometry>,
    /// Render-thread-private copy. `hx_grid_acquire` refreshes it from the
    /// receive thread's buffer, so pointers handed to the caller stay valid
    /// without holding a lock across the FFI boundary.
    front: Grid,
    /// Image bytes copied out for the caller, for the same reason.
    front_asset: Vec<u8>,
}

impl HxSession {
    /// Points the cached handles at the endpoint at `index`.
    fn select(&mut self, index: usize) {
        let Some(endpoint) = self.endpoints.get(index) else {
            return;
        };
        self.active = index;
        self.shared = Arc::clone(&endpoint.shared);
        self.outbound = endpoint.outbound.clone();
        // The new surface has not arrived yet; showing the previous machine's
        // grid under the new machine's name would be worse than showing none.
        self.front = Grid::default();
    }
}

/// Connects to every endpoint: the local server and each saved SSH machine.
///
/// Returns as soon as the endpoints exist, without waiting for any of them.
/// Reaching a machine over ssh can take seconds, and the window should be up
/// and showing local work long before that resolves.
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
    let discovered = crate::endpoint::discover();
    let selection = crate::endpoint::saved_selection();
    let active = selection
        .and_then(|id| discovered.iter().position(|e| e.id == id))
        .unwrap_or(0);

    let mut endpoints = Vec::new();
    for (index, endpoint) in discovered.into_iter().enumerate() {
        endpoints.push(spawn_endpoint(
            endpoint,
            index == active,
            Geometry {
                cols,
                rows,
                cell_width_px,
                cell_height_px,
            },
        ));
    }

    if endpoints.is_empty() {
        *LAST_CONNECT_ERROR().lock().unwrap() = Some("no endpoints configured".into());
        return std::ptr::null_mut();
    }

    let active = active.min(endpoints.len() - 1);
    let shared = Arc::clone(&endpoints[active].shared);
    let outbound = endpoints[active].outbound.clone();
    Box::into_raw(Box::new(HxSession {
        endpoints,
        active,
        shared,
        outbound,
        geometry: Mutex::new(Geometry {
            cols,
            rows,
            cell_width_px,
            cell_height_px,
        }),
        front: Grid::default(),
        front_asset: Vec::new(),
    }))
}

/// Starts one endpoint's connection and receive loop on its own thread.
fn spawn_endpoint(
    endpoint: crate::endpoint::Endpoint,
    surface_active: bool,
    geometry: Geometry,
) -> EndpointState {
    let shared = Arc::new(Shared {
        grid: Mutex::new(Grid::default()),
        boot_id: Mutex::new(None),
        desired_surface: AtomicBool::new(surface_active),
        applied_surface: AtomicBool::new(surface_active),
        geometry: Mutex::new(geometry),
        resync_pending: AtomicBool::new(false),
        snapshot_json: Mutex::new(None),
        error: Mutex::new(None),
        events: Mutex::new(std::collections::VecDeque::new()),
        assets: Mutex::new(AssetCache::default()),
        connected: AtomicBool::new(false),
    });
    let status = Arc::new(std::sync::atomic::AtomicU8::new(HX_ENDPOINT_CONNECTING));
    let (tx, rx) = std::sync::mpsc::channel::<ClientMessage>();

    // Outbound messages are funnelled through one queue that survives
    // reconnects, so input is never lost to a machine that briefly went away.
    let outbound = Arc::new(Mutex::new(
        None::<crate::endpoint::WriteHalf>,
    ));
    let writer_slot = Arc::clone(&outbound);
    std::thread::spawn(move || {
        for message in rx {
            let mut slot = writer_slot.lock().unwrap();
            if let Some(writer) = slot.as_mut() {
                if crate::protocol::write_message(writer, &message).is_err()
                    || writer.flush().is_err()
                {
                    // The connection went away; the endpoint thread will
                    // install a new writer when it reconnects.
                    *slot = None;
                }
            }
        }
    });

    let thread_shared = Arc::clone(&shared);
    let thread_status = Arc::clone(&status);
    let thread_endpoint = endpoint.clone();
    let thread_outbound = tx.clone();
    std::thread::spawn(move || {
        let socket = default_socket_path();
        let mut backoff = std::time::Duration::from_millis(250);

        loop {
            let hello = crate::client::hello_with_surface(
                geometry.cols,
                geometry.rows,
                geometry.cell_width_px,
                geometry.cell_height_px,
                surface_active,
            );

            match crate::client::EndpointConnection::attach(&thread_endpoint, &socket, &hello) {
                Ok(mut conn) => {
                    *outbound.lock().unwrap() = conn.take_writer();
                    thread_shared.connected.store(true, Ordering::Release);
                    thread_status.store(HX_ENDPOINT_ONLINE, Ordering::Release);
                    backoff = std::time::Duration::from_millis(250);

                    receive_loop(
                        conn,
                        Arc::clone(&thread_shared),
                        Arc::clone(&thread_status),
                        thread_outbound.clone(),
                    );
                    *outbound.lock().unwrap() = None;
                }
                Err(err) => {
                    *thread_shared.error.lock().unwrap() =
                        Some(format!("{}: {err}", thread_endpoint.label));
                    thread_status.store(HX_ENDPOINT_OFFLINE, Ordering::Release);
                }
            }

            // Each endpoint reconnects on its own. A machine that is asleep
            // must not stop the others from working, which is what a
            // session-wide retry would do.
            std::thread::sleep(backoff);
            backoff = (backoff * 2).min(std::time::Duration::from_secs(10));
            thread_status.store(HX_ENDPOINT_CONNECTING, Ordering::Release);
        }
    });

    EndpointState {
        endpoint,
        shared,
        outbound: tx,
        status,
    }
}

/// Reads from one endpoint until it goes away.
/// Asks the server for a complete surface after we had to refuse a patch.
///
/// The server tracks surface revisions per connection and has no idea a patch
/// was rejected, so it keeps sending patches built on a revision we no longer
/// hold and every one is refused — the view freezes until something forces a
/// recompute. A resize does, even at the size we already have.
fn request_resync(shared: &Shared, outbound: &std::sync::mpsc::Sender<ClientMessage>) {
    if shared.resync_pending.swap(true, Ordering::AcqRel) {
        return;
    }
    let geometry = *shared.geometry.lock().unwrap();
    let _ = outbound.send(ClientMessage::ClientShellResize {
        cell_width_px: geometry.cell_width_px,
        cell_height_px: geometry.cell_height_px,
        surface_size: herdr_protocol::protocol::ClientSurfaceSize {
            cols: geometry.cols,
            rows: geometry.rows,
        },
        pixel_mouse: true,
    });
}

/// Asks the server to start or stop composing a surface for this connection.
///
/// Returns false when the boot id is not known yet; the caller retries when the
/// next snapshot arrives.
fn apply_surface_state(
    shared: &Shared,
    outbound: &std::sync::mpsc::Sender<ClientMessage>,
) -> bool {
    let desired = shared.desired_surface.load(Ordering::Acquire);
    if desired == shared.applied_surface.load(Ordering::Acquire) {
        return true;
    }
    let Some(boot_id) = shared.boot_id.lock().unwrap().clone() else {
        return false;
    };
    let request = format!(
        r#"{{"id":"surface.set","method":"client_shell.surface.set","params":{{"active":{desired}}}}}"#
    );
    if outbound
        .send(ClientMessage::ClientShellEndpointRequest { boot_id, request })
        .is_err()
    {
        return false;
    }
    shared.applied_surface.store(desired, Ordering::Release);
    true
}

fn receive_loop(
    mut conn: crate::client::EndpointConnection,
    loop_shared: Arc<Shared>,
    status: Arc<std::sync::atomic::AtomicU8>,
    outbound: std::sync::mpsc::Sender<ClientMessage>,
) {
    let mut pending = PendingResponses::default();
    // Every message goes through this, including plain ones: the compact
    // encodings are expressed against the baseline it maintains.
    let mut decoder = herdr_protocol::protocol::SurfaceDecoder::new(true);
    loop {
        let received = conn.recv().and_then(|message| {
            decoder.decode(message).map_err(|error| {
                // The baseline has diverged from the sender, so nothing further
                // can be decoded against it. Start again from a full surface.
                decoder.reset();
                std::io::Error::other(format!("surface decode failed: {error}"))
            })
        });
        if let Err(error) = &received {
            if error.to_string().starts_with("surface decode failed") {
                *loop_shared.error.lock().unwrap() = Some(error.to_string());
                request_resync(&loop_shared, &outbound);
                continue;
            }
        }
        match received {
        Ok(ServerMessage::PaneSurface(frame)) => {
            let mut assets = loop_shared.assets.lock().unwrap();
            loop_shared.grid.lock().unwrap().replace(&frame, &mut assets);
            loop_shared.resync_pending.store(false, Ordering::Release);
        }
        Ok(ServerMessage::PaneSurfacePatch(patch)) => {
            let mut grid = loop_shared.grid.lock().unwrap();
            if !grid.apply_patch(&patch) {
                // Keep the last coherent surface rather than a stitched one,
                // and ask for a complete one: the server does not know the
                // patch was refused, so without this every later patch is
                // refused too and the view stops updating.
                let held = grid.revision;
                drop(grid);
                *loop_shared.error.lock().unwrap() = Some(format!(
                    "refused surface patch {} built on revision {}; held {held} and asked for a full surface",
                    patch.surface_revision, patch.base_surface_revision
                ));
                request_resync(&loop_shared, &outbound);
            }
        }
        Ok(ServerMessage::EndpointControl { kind, data })
            if kind == herdr_protocol::protocol::endpoint::ENDPOINT_SNAPSHOT_KIND =>
        {
            if let Ok(parsed) = serde_json::from_str::<SnapshotBootId>(&data) {
                let mut boot_id = loop_shared.boot_id.lock().unwrap();
                if boot_id.as_deref() != Some(parsed.boot_id.as_str()) {
                    // A new boot invalidates whatever the old server was told,
                    // so the surface state has to be asserted again.
                    *boot_id = Some(parsed.boot_id);
                    drop(boot_id);
                    loop_shared.applied_surface.store(
                        !loop_shared.desired_surface.load(Ordering::Acquire),
                        Ordering::Release,
                    );
                }
            }
            apply_surface_state(&loop_shared, &outbound);
            *loop_shared.snapshot_json.lock().unwrap() = Some(data);
        }
        Ok(ServerMessage::SemanticNotification(notification)) => {
            loop_shared.push(semantic_event(notification));
        }
        Ok(ServerMessage::Notify { kind, message, body }) => {
            // Only the host-notification kind is ours to present; the toast
            // kinds are for a client drawing herdr's own TUI chrome.
            if matches!(kind, herdr_protocol::protocol::NotifyKind::SystemToast) {
                loop_shared.push(Event::Notification {
                    kind: "custom".into(),
                    title: message,
                    body,
                    sound: None,
                    agent: None,
                    workspace_id: None,
                    tab_id: None,
                    pane_id: None,
                });
            }
        }
        Ok(ServerMessage::Clipboard { data }) => {
            use base64::Engine as _;
            if let Some(text) = base64::engine::general_purpose::STANDARD
                .decode(data.as_bytes())
                .ok()
                .and_then(|bytes| String::from_utf8(bytes).ok())
            {
                loop_shared.push(Event::Clipboard { text });
            }
        }
        Ok(ServerMessage::WindowTitle { title }) => {
            loop_shared.push(Event::WindowTitle { title });
        }
        Ok(ServerMessage::TerminalBell { count }) => {
            loop_shared.push(Event::Bell { count });
        }
        Ok(ServerMessage::ClientShellError { message }) => {
            loop_shared.push(Event::Error { message });
        }
        Ok(ServerMessage::ClientShellEndpointResponseChunk {
            request_id,
            final_chunk,
            data,
            ..
        }) => {
            if let Some((request_id, body)) = pending.push(request_id, &data, final_chunk) {
                loop_shared.push(Event::Response { request_id, body });
            }
        }
        Ok(_) => {}
        Err(err) => {
            *loop_shared.error.lock().unwrap() = Some(format!("{err}"));
            loop_shared.connected.store(false, Ordering::Release);
            status.store(HX_ENDPOINT_OFFLINE, Ordering::Release);
            return;
        }
        }
    }
}


/// # Safety
/// `session` must come from `hx_session_connect`/// # Safety
/// `session` must come from `hx_session_connect` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn hx_session_free(session: *mut HxSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

/// Why the most recent `hx_session_connect` failed. Caller frees with
/// `hx_string_free`.
#[no_mangle]
pub extern "C" fn hx_connect_error() -> *mut c_char {
    string_or_null(LAST_CONNECT_ERROR().lock().unwrap().take())
}

/// How many machines are attached.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_count(session: *const HxSession) -> usize {
    session.as_ref().map_or(0, |s| s.endpoints.len())
}

/// The endpoint's opaque id. Caller frees with `hx_string_free`.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_id(session: *const HxSession, index: usize) -> *mut c_char {
    string_or_null(
        session
            .as_ref()
            .and_then(|s| s.endpoints.get(index))
            .map(|e| e.endpoint.id.clone()),
    )
}

/// The endpoint's display name. Caller frees with `hx_string_free`.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_label(session: *const HxSession, index: usize) -> *mut c_char {
    string_or_null(
        session
            .as_ref()
            .and_then(|s| s.endpoints.get(index))
            .map(|e| e.endpoint.label.clone()),
    )
}

/// One of `HX_ENDPOINT_*`.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_status(session: *const HxSession, index: usize) -> u8 {
    session
        .as_ref()
        .and_then(|s| s.endpoints.get(index))
        .map_or(HX_ENDPOINT_OFFLINE, |e| e.status.load(Ordering::Acquire))
}

/// Whether the endpoint is reached over ssh rather than the local socket.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_is_remote(session: *const HxSession, index: usize) -> bool {
    session
        .as_ref()
        .and_then(|s| s.endpoints.get(index))
        .is_some_and(|e| !matches!(e.endpoint.kind, crate::endpoint::EndpointKind::Local))
}

/// Which endpoint currently renders a surface and takes input.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_active_endpoint(session: *const HxSession) -> usize {
    session.as_ref().map_or(0, |s| s.active)
}

/// Switches which machine is shown.
///
/// Every endpoint stays connected either way — that is what keeps remote agent
/// status live in the sidebar — but only the active one is asked to render a
/// surface, so the cost of watching several machines stays small.
///
/// # Safety
/// `session` must be a live session pointer, used from one thread at a time.
#[no_mangle]
pub unsafe extern "C" fn hx_set_active_endpoint(session: *mut HxSession, index: usize) -> bool {
    let Some(session) = session.as_mut() else {
        return false;
    };
    if index >= session.endpoints.len() {
        return false;
    }
    if index == session.active {
        return true;
    }

    let geometry = *session.geometry.lock().unwrap();
    for (position, endpoint) in session.endpoints.iter().enumerate() {
        let active = position == index;
        endpoint
            .shared
            .desired_surface
            .store(active, Ordering::Release);
        // Applied here when the boot id is known, and otherwise by the receive
        // loop as soon as a snapshot brings one.
        apply_surface_state(&endpoint.shared, &endpoint.outbound);
        if active {
            let _ = endpoint.outbound.send(ClientMessage::ClientShellResize {
                cell_width_px: geometry.cell_width_px,
                cell_height_px: geometry.cell_height_px,
                surface_size: herdr_protocol::protocol::ClientSurfaceSize {
                    cols: geometry.cols,
                    rows: geometry.rows,
                },
                pixel_mouse: true,
            });
        }
    }

    session.select(index);
    true
}

/// The latest snapshot for one endpoint, or null. Caller frees with
/// `hx_string_free`.
///
/// Each machine has its own workspace tree, so the sidebar reads them all
/// rather than only the active one.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_snapshot_json(
    session: *const HxSession,
    index: usize,
) -> *mut c_char {
    string_or_null(
        session
            .as_ref()
            .and_then(|s| s.endpoints.get(index))
            .and_then(|e| e.shared.snapshot_json.lock().unwrap().take()),
    )
}

/// Pops the next event from any endpoint, oldest first within each.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_next_endpoint_event(
    session: *const HxSession,
    index: usize,
) -> *mut c_char {
    string_or_null(
        session
            .as_ref()
            .and_then(|s| s.endpoints.get(index))
            .and_then(|e| e.shared.events.lock().unwrap().pop_front()),
    )
}

fn string_or_null(value: Option<String>) -> *mut c_char {
    match value.and_then(|s| CString::new(s).ok()) {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Whether any endpoint is currently attached.
///
/// Endpoints reconnect individually, so this is about whether the session is
/// worth keeping rather than a prompt to rebuild it.
///
/// # Safety
/// `session` must be a live session pointer.
#[no_mangle]
pub unsafe extern "C" fn hx_session_connected(session: *const HxSession) -> bool {
    session.as_ref().is_some_and(|s| {
        s.endpoints
            .iter()
            .any(|e| e.shared.connected.load(Ordering::Acquire))
    })
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
            placements: front.placements.as_ptr(),
            placement_count: front.placements.len(),
        },
    );
    true
}

/// Looks up image bytes by the id a placement carries.
///
/// The bytes are copied into session-owned storage, so the pointer stays valid
/// until the next `hx_asset` call rather than only while the receive thread
/// happens not to be touching its cache.
///
/// # Safety
/// `session` must be a live session pointer, used from one thread at a time,
/// and `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hx_asset(
    session: *mut HxSession,
    asset_id: u64,
    out: *mut HxAsset,
) -> bool {
    use herdr_protocol::protocol::SurfaceGraphicsFormat as F;
    let (Some(session), false) = (session.as_mut(), out.is_null()) else {
        return false;
    };
    let (width, height, format) = {
        let assets = session.shared.assets.lock().unwrap();
        let Some(asset) = assets.assets.get(&asset_id) else {
            return false;
        };
        session.front_asset.clear();
        session.front_asset.extend_from_slice(&asset.data);
        (asset.key.image_width, asset.key.image_height, asset.key.format)
    };
    std::ptr::write(
        out,
        HxAsset {
            width,
            height,
            format: match format {
                F::Rgb => HX_IMAGE_RGB,
                F::Rgba => HX_IMAGE_RGBA,
                F::Png => HX_IMAGE_PNG,
            },
            data: session.front_asset.as_ptr(),
            len: session.front_asset.len(),
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



/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_last_error(session: *const HxSession) -> *mut c_char {
    let Some(session) = session.as_ref() else {
        return std::ptr::null_mut();
    };
    // Every endpoint, not just the active one: a machine failing in the
    // background is exactly the failure you cannot see any other way.
    for endpoint in &session.endpoints {
        if let Some(message) = endpoint.shared.error.lock().unwrap().take() {
            return string_or_null(Some(message));
        }
    }
    std::ptr::null_mut()
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

/// Pastes text into a pane.
///
/// This is distinct from `hx_send_text`: herdr models a paste separately so the
/// pane can wrap it in bracketed-paste markers when the program asked for them,
/// which is what stops an editor from interpreting pasted text as commands.
///
/// # Safety
/// `session` must be live and both strings valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_send_paste(
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
            events: vec![herdr_protocol::protocol::ClientPaneInputEvent::Paste(
                text.to_owned(),
            )],
        })
        .is_ok()
}

/// Publishes the host's default foreground or background colour.
///
/// Cells whose colour is `Reset` mean "the terminal's default", and the server
/// resolves that when composing surfaces. Telling it what our default actually
/// is keeps server-composed chrome matching the app's theme.
///
/// # Safety
/// `session` must be live.
/// Sends a host-theme update to every endpoint.
///
/// The window has one palette, so every machine attached to it needs to be
/// told: a surface composed against another machine's idea of the default
/// background is the wrong colour the moment you switch to it, and switching
/// is not something the theme changes in response to.
fn broadcast_host_theme(
    session: &HxSession,
    update: herdr_protocol::protocol::ClientHostThemeUpdate,
) -> bool {
    let mut sent = false;
    for endpoint in &session.endpoints {
        sent |= endpoint
            .outbound
            .send(ClientMessage::ClientShellHostTheme {
                update: update.clone(),
            })
            .is_ok();
    }
    sent
}

#[no_mangle]
pub unsafe extern "C" fn hx_set_default_color(
    session: *const HxSession,
    foreground: bool,
    r: u8,
    g: u8,
    b: u8,
) -> bool {
    use herdr_protocol::protocol::{
        ClientHostColor, ClientHostDefaultColorKind, ClientHostThemeUpdate,
    };
    let Some(session) = session.as_ref() else {
        return false;
    };
    broadcast_host_theme(
        session,
        ClientHostThemeUpdate::DefaultColor {
            kind: if foreground {
                ClientHostDefaultColorKind::Foreground
            } else {
                ClientHostDefaultColorKind::Background
            },
            color: ClientHostColor { r, g, b },
        },
    )
}

/// Publishes whether the app is currently in light or dark appearance.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_set_appearance(session: *const HxSession, dark: bool) -> bool {
    use herdr_protocol::protocol::{ClientHostAppearance, ClientHostThemeUpdate};
    let Some(session) = session.as_ref() else {
        return false;
    };
    broadcast_host_theme(
        session,
        ClientHostThemeUpdate::Appearance(if dark {
            ClientHostAppearance::Dark
        } else {
            ClientHostAppearance::Light
        }),
    )
}

/// Publishes the 16 ANSI palette entries, so `Indexed` colours resolve to the
/// same values the app draws with.
///
/// `colors` is `count * 3` bytes of RGB, starting at palette index 0.
///
/// # Safety
/// `session` must be live and `colors` must point to `count * 3` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn hx_set_palette(
    session: *const HxSession,
    colors: *const u8,
    count: usize,
) -> bool {
    use herdr_protocol::protocol::{ClientHostColor, ClientHostThemeUpdate};
    let (Some(session), false) = (session.as_ref(), colors.is_null()) else {
        return false;
    };
    let bytes = std::slice::from_raw_parts(colors, count * 3);
    let entries = (0..count)
        .map(|i| {
            (
                i as u8,
                ClientHostColor {
                    r: bytes[i * 3],
                    g: bytes[i * 3 + 1],
                    b: bytes[i * 3 + 2],
                },
            )
        })
        .collect();
    broadcast_host_theme(session, ClientHostThemeUpdate::PaletteColors(entries))
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
    *session.geometry.lock().unwrap() = Geometry {
        cols,
        rows,
        cell_width_px,
        cell_height_px,
    };
    // Tell every endpoint, not just the active one: switching machines should
    // not show a surface composed for the wrong window size.
    for endpoint in &session.endpoints {
        *endpoint.shared.geometry.lock().unwrap() = Geometry {
            cols,
            rows,
            cell_width_px,
            cell_height_px,
        };
        let _ = endpoint.outbound.send(ClientMessage::ClientShellResize {
            cell_width_px,
            cell_height_px,
            surface_size: herdr_protocol::protocol::ClientSurfaceSize { cols, rows },
            pixel_mouse: true,
        });
    }
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

    /// Installs a surface the way the receive loop does.
    fn install(grid: &mut Grid, frame: &PaneSurfaceFrame) {
        let mut assets = AssetCache::default();
        grid.replace(frame, &mut assets);
    }

    fn text(grid: &Grid) -> String {
        grid.source.iter().map(|c| c.symbol.as_str()).collect()
    }

    #[test]
    fn full_surface_populates_the_flattened_view() {
        let mut grid = Grid::default();
        install(&mut grid, &surface(1));

        assert_eq!(text(&grid), "abcdef");
        assert_eq!(grid.cells.len(), 6);
        assert_eq!(grid.pane_ids, vec!["p1".to_string()]);
        assert!(grid.cursor_visible);
        assert_eq!((grid.cursor_x, grid.cursor_y, grid.cursor_shape), (1, 0, 2));
    }

    #[test]
    fn patch_updates_only_the_spans_it_carries() {
        let mut grid = Grid::default();
        install(&mut grid, &surface(1));

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
        install(&mut grid, &surface(1));
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
        install(&mut grid, &surface(1));

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
        install(&mut grid, &surface(1));

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

    fn geometry() -> Geometry {
        Geometry { cols: 80, rows: 24, cell_width_px: 9, cell_height_px: 16 }
    }

    fn mouse(kind: u16, button: u8, lines: u16) -> HxMouseEvent {
        HxMouseEvent {
            kind,
            button,
            column: 4,
            row: 3,
            pixel_x: 40,
            pixel_y: 52,
            modifiers: 0,
            lines,
        }
    }

    fn shared() -> Shared {
        Shared {
            grid: Mutex::new(Grid::default()),
            boot_id: Mutex::new(None),
            desired_surface: AtomicBool::new(false),
            applied_surface: AtomicBool::new(false),
            geometry: Mutex::new(Geometry {
                cols: 80,
                rows: 24,
                cell_width_px: 8,
                cell_height_px: 16,
            }),
            resync_pending: AtomicBool::new(false),
            snapshot_json: Mutex::new(None),
            error: Mutex::new(None),
            events: Mutex::new(std::collections::VecDeque::new()),
            assets: Mutex::new(AssetCache::default()),
            connected: AtomicBool::new(false),
        }
    }

    fn notification(
        kind: herdr_protocol::protocol::SemanticNotificationKind,
    ) -> herdr_protocol::protocol::SemanticNotification {
        herdr_protocol::protocol::SemanticNotification {
            kind,
            title: "claude needs input".into(),
            body: Some("waiting on approval".into()),
            sound: Some(herdr_protocol::protocol::SemanticNotificationSound::Request),
            agent: Some("claude".into()),
            workspace_id: Some("w1".into()),
            tab_id: Some("t1".into()),
            pane_id: Some("p1".into()),
            position: None,
        }
    }

    #[test]
    fn semantic_notifications_keep_their_kind_and_routing() {
        use herdr_protocol::protocol::SemanticNotificationKind as K;
        let event = semantic_event(notification(K::NeedsAttention));
        let json = serde_json::to_value(&event).unwrap();

        assert_eq!(json["type"], "notification");
        assert_eq!(json["kind"], "needs_attention");
        assert_eq!(json["title"], "claude needs input");
        assert_eq!(json["sound"], "request");
        // Routing ids let the UI jump to the pane that wants attention.
        assert_eq!(json["pane_id"], "p1");
        assert_eq!(json["agent"], "claude");

        for (kind, expected) in [
            (K::Finished, "finished"),
            (K::UpdateInstalled, "update_installed"),
            (K::Custom, "custom"),
        ] {
            let json = serde_json::to_value(semantic_event(notification(kind))).unwrap();
            assert_eq!(json["kind"], expected);
        }
    }

    /// A UI that stops draining must not make the receive thread grow memory
    /// without bound, and the newest agent state is what matters.
    #[test]
    fn the_event_queue_drops_the_oldest_when_full() {
        let shared = shared();
        for count in 0..300u16 {
            shared.push(Event::Bell { count });
        }

        let queue = shared.events.lock().unwrap();
        assert_eq!(queue.len(), 256);
        let first: serde_json::Value = serde_json::from_str(queue.front().unwrap()).unwrap();
        let last: serde_json::Value = serde_json::from_str(queue.back().unwrap()).unwrap();
        assert_eq!(first["count"], 44, "oldest events should be dropped");
        assert_eq!(last["count"], 299, "newest event must survive");
    }

    fn surface_request(message: &ClientMessage) -> (String, bool) {
        let ClientMessage::ClientShellEndpointRequest { boot_id, request } = message else {
            panic!("expected an endpoint request");
        };
        (boot_id.clone(), request.contains(r#""active":true"#))
    }

    /// The server rejects a command carrying an unknown boot id with
    /// `stale_boot`, so the request must wait for a snapshot rather than go out
    /// with a placeholder — which silently left the new machine blank.
    /// A refused patch must trigger a request for a complete surface. The
    /// server does not know the patch was refused, so without this every later
    /// patch is refused too and the view silently stops updating.
    #[test]
    fn a_refused_patch_asks_for_a_full_surface() {
        let shared = shared();
        let (tx, rx) = std::sync::mpsc::channel();
        *shared.geometry.lock().unwrap() = Geometry {
            cols: 100,
            rows: 40,
            cell_width_px: 9,
            cell_height_px: 18,
        };

        request_resync(&shared, &tx);

        let ClientMessage::ClientShellResize { surface_size, .. } = rx.try_recv().unwrap() else {
            panic!("a resync should ask for a resize, which forces a recompute");
        };
        assert_eq!((surface_size.cols, surface_size.rows), (100, 40));
    }

    /// One refused patch must not produce a resize per frame.
    #[test]
    fn resync_requests_do_not_pile_up() {
        let shared = shared();
        let (tx, rx) = std::sync::mpsc::channel();

        request_resync(&shared, &tx);
        request_resync(&shared, &tx);
        request_resync(&shared, &tx);

        assert!(rx.try_recv().is_ok());
        assert!(rx.try_recv().is_err(), "only one request until a surface lands");

        // A complete surface clears the flag, so a later desync can recover.
        shared.resync_pending.store(false, Ordering::Release);
        request_resync(&shared, &tx);
        assert!(rx.try_recv().is_ok());
    }

    #[test]
    fn surface_state_waits_for_a_boot_id() {
        let shared = shared();
        let (tx, rx) = std::sync::mpsc::channel();

        shared.desired_surface.store(true, Ordering::Release);
        assert!(!apply_surface_state(&shared, &tx), "no boot id yet");
        assert!(rx.try_recv().is_err(), "nothing may be sent without a boot id");
        assert!(
            !shared.applied_surface.load(Ordering::Acquire),
            "an unsent request must not be recorded as applied"
        );

        *shared.boot_id.lock().unwrap() = Some("boot-1".into());
        assert!(apply_surface_state(&shared, &tx));
        assert_eq!(surface_request(&rx.try_recv().unwrap()), ("boot-1".into(), true));
    }

    #[test]
    fn surface_state_is_not_resent_once_applied() {
        let shared = shared();
        let (tx, rx) = std::sync::mpsc::channel();
        *shared.boot_id.lock().unwrap() = Some("boot-1".into());

        shared.desired_surface.store(true, Ordering::Release);
        assert!(apply_surface_state(&shared, &tx));
        assert!(rx.try_recv().is_ok());

        assert!(apply_surface_state(&shared, &tx));
        assert!(rx.try_recv().is_err(), "an unchanged state should send nothing");
    }

    /// A restarted server knows nothing of what the old one was told, so the
    /// surface state has to be asserted again against the new boot.
    #[test]
    fn a_new_boot_reasserts_the_surface_state() {
        let shared = shared();
        let (tx, rx) = std::sync::mpsc::channel();
        *shared.boot_id.lock().unwrap() = Some("boot-1".into());
        shared.desired_surface.store(true, Ordering::Release);
        assert!(apply_surface_state(&shared, &tx));
        assert_eq!(surface_request(&rx.try_recv().unwrap()).0, "boot-1");

        // What the receive loop does when a snapshot carries a different boot.
        *shared.boot_id.lock().unwrap() = Some("boot-2".into());
        shared.applied_surface.store(
            !shared.desired_surface.load(Ordering::Acquire),
            Ordering::Release,
        );

        assert!(apply_surface_state(&shared, &tx));
        assert_eq!(
            surface_request(&rx.try_recv().unwrap()),
            ("boot-2".into(), true),
            "the new boot must be told the surface is wanted"
        );
    }

    #[test]
    fn mouse_events_map_to_their_protocol_kinds() {
        use herdr_protocol::protocol::{ClientMouseButton as B, ClientMouseKind as K};
        let cases = [
            (HX_MOUSE_DOWN, HX_BUTTON_LEFT, K::Down(B::Left)),
            (HX_MOUSE_UP, HX_BUTTON_RIGHT, K::Up(B::Right)),
            (HX_MOUSE_DRAG, HX_BUTTON_MIDDLE, K::Drag(B::Middle)),
            (HX_MOUSE_SCROLL_UP, HX_BUTTON_LEFT, K::ScrollUp),
            (HX_MOUSE_SCROLL_DOWN, HX_BUTTON_LEFT, K::ScrollDown),
        ];
        for (kind, button, expected) in cases {
            assert_eq!(mouse_kind(kind, button), Some(expected), "kind {kind}");
        }
        assert_eq!(mouse_kind(999, HX_BUTTON_LEFT), None);
        assert_eq!(mouse_kind(HX_MOUSE_DOWN, 42), None);
    }

    /// Panes running SGR pixel mouse need exact pixel geometry, so the message
    /// must carry the real surface size rather than a cell-rounded guess.
    #[test]
    fn mouse_message_carries_exact_pixel_geometry() {
        use herdr_protocol::protocol::{ClientMouseGeometry, ClientMousePosition, ClientPaneInputEvent};
        let kind = mouse_kind(HX_MOUSE_DOWN, HX_BUTTON_LEFT).unwrap();
        let message = mouse_message("p1", &mouse(HX_MOUSE_DOWN, HX_BUTTON_LEFT, 0), kind, geometry());

        let ClientMessage::ClientShellPaneInput { pane_id, events } = message else {
            panic!("mouse input must target a pane");
        };
        assert_eq!(pane_id, "p1");
        let ClientPaneInputEvent::Mouse { position, geometry: g, lines, .. } = &events[0] else {
            panic!("expected a mouse event");
        };
        assert_eq!(
            *position,
            ClientMousePosition::Pixels { x: 40, y: 52, column: 4, row: 3 }
        );
        assert_eq!(
            *g,
            Some(ClientMouseGeometry { cols: 80, rows: 24, width_px: 720, height_px: 384 })
        );
        assert_eq!(*lines, 1, "a zero-row scroll should still move one row");
    }

    #[test]
    fn scroll_rows_are_preserved() {
        let kind = mouse_kind(HX_MOUSE_SCROLL_DOWN, HX_BUTTON_LEFT).unwrap();
        let message = mouse_message(
            "p1",
            &mouse(HX_MOUSE_SCROLL_DOWN, HX_BUTTON_LEFT, 5),
            kind,
            geometry(),
        );
        let ClientMessage::ClientShellPaneInput { events, .. } = message else { unreachable!() };
        let herdr_protocol::protocol::ClientPaneInputEvent::Mouse { lines, .. } = &events[0] else {
            unreachable!()
        };
        assert_eq!(*lines, 5);
    }

    #[test]
    fn patch_pane_metadata_merges_in_place() {
        let mut grid = Grid::default();
        install(&mut grid, &surface(1));

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


fn semantic_event(notification: herdr_protocol::protocol::SemanticNotification) -> Event {
    use herdr_protocol::protocol::{SemanticNotificationKind as K, SemanticNotificationSound as S};
    Event::Notification {
        kind: match notification.kind {
            K::NeedsAttention => "needs_attention",
            K::Finished => "finished",
            K::UpdateInstalled => "update_installed",
            K::Custom => "custom",
        }
        .into(),
        title: notification.title,
        body: notification.body,
        sound: notification.sound.map(|sound| {
            match sound {
                S::Done => "done",
                S::Request => "request",
            }
            .into()
        }),
        agent: notification.agent,
        workspace_id: notification.workspace_id,
        tab_id: notification.tab_id,
        pane_id: notification.pane_id,
    }
}

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

pub const HX_MOUSE_DOWN: u16 = 0;
pub const HX_MOUSE_UP: u16 = 1;
pub const HX_MOUSE_DRAG: u16 = 2;
pub const HX_MOUSE_MOVED: u16 = 3;
pub const HX_MOUSE_SCROLL_UP: u16 = 4;
pub const HX_MOUSE_SCROLL_DOWN: u16 = 5;
pub const HX_MOUSE_SCROLL_LEFT: u16 = 6;
pub const HX_MOUSE_SCROLL_RIGHT: u16 = 7;

pub const HX_BUTTON_LEFT: u8 = 0;
pub const HX_BUTTON_RIGHT: u8 = 1;
pub const HX_BUTTON_MIDDLE: u8 = 2;

/// One mouse event in surface coordinates.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxMouseEvent {
    pub kind: u16,
    pub button: u8,
    /// Cell coordinates, relative to the surface origin.
    pub column: u16,
    pub row: u16,
    /// Pixel coordinates within the surface, for SGR pixel mouse.
    pub pixel_x: u32,
    pub pixel_y: u32,
    pub modifiers: u8,
    /// Rows to move for a scroll event.
    pub lines: u16,
}

fn mouse_kind(kind: u16, button: u8) -> Option<herdr_protocol::protocol::ClientMouseKind> {
    use herdr_protocol::protocol::{ClientMouseButton as B, ClientMouseKind as K};
    let button = match button {
        HX_BUTTON_LEFT => B::Left,
        HX_BUTTON_RIGHT => B::Right,
        HX_BUTTON_MIDDLE => B::Middle,
        _ => return None,
    };
    Some(match kind {
        HX_MOUSE_DOWN => K::Down(button),
        HX_MOUSE_UP => K::Up(button),
        HX_MOUSE_DRAG => K::Drag(button),
        HX_MOUSE_MOVED => K::Moved,
        HX_MOUSE_SCROLL_UP => K::ScrollUp,
        HX_MOUSE_SCROLL_DOWN => K::ScrollDown,
        HX_MOUSE_SCROLL_LEFT => K::ScrollLeft,
        HX_MOUSE_SCROLL_RIGHT => K::ScrollRight,
        _ => return None,
    })
}

/// Delivers one mouse event to a pane.
///
/// The server decides what it means: a pane whose program requested mouse
/// reporting gets the event encoded for it, and otherwise herdr treats scrolls
/// as history navigation. That policy is deliberately not duplicated here.
///
/// # Safety
/// `session` must be live, `pane_id` valid NUL-terminated UTF-8, and `event`
/// must point to a readable `HxMouseEvent`.
#[no_mangle]
pub unsafe extern "C" fn hx_send_mouse(
    session: *const HxSession,
    pane_id: *const c_char,
    event: *const HxMouseEvent,
) -> bool {
    let (Some(session), false, false) = (session.as_ref(), pane_id.is_null(), event.is_null())
    else {
        return false;
    };
    let Ok(pane_id) = CStr::from_ptr(pane_id).to_str() else {
        return false;
    };
    let event = *event;
    let Some(kind) = mouse_kind(event.kind, event.button) else {
        return false;
    };

    let geometry = *session.geometry.lock().unwrap();
    session
        .outbound
        .send(mouse_message(pane_id, &event, kind, geometry))
        .is_ok()
}

fn mouse_message(
    pane_id: &str,
    event: &HxMouseEvent,
    kind: herdr_protocol::protocol::ClientMouseKind,
    geometry: Geometry,
) -> ClientMessage {
    ClientMessage::ClientShellPaneInput {
        pane_id: pane_id.to_owned(),
        events: vec![herdr_protocol::protocol::ClientPaneInputEvent::Mouse {
            kind,
            position: herdr_protocol::protocol::ClientMousePosition::Pixels {
                x: event.pixel_x,
                y: event.pixel_y,
                column: event.column,
                row: event.row,
            },
            geometry: Some(herdr_protocol::protocol::ClientMouseGeometry {
                cols: geometry.cols,
                rows: geometry.rows,
                width_px: u32::from(geometry.cols) * geometry.cell_width_px,
                height_px: u32::from(geometry.rows) * geometry.cell_height_px,
            }),
            modifiers: event.modifiers,
            // A scroll of zero rows would be a no-op the server still has to
            // process; treat it as the single row the gesture implied.
            lines: event.lines.max(1),
        }],
    }
}

#[allow(non_snake_case)]
fn LAST_MACHINE_ERROR() -> &'static Mutex<Option<String>> {
    static CELL: std::sync::OnceLock<Mutex<Option<String>>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(None))
}

// MARK: - Machines

/// The SSH machines herdr knows about, as a JSON array.
///
/// Read from herdr's catalog rather than from the live session: a machine that
/// is disabled, or that failed to connect, still has to be listed and edited.
///
/// # Safety
/// The returned pointer must be released with `hx_string_free`.
#[no_mangle]
pub unsafe extern "C" fn hx_machines_json() -> *mut c_char {
    let machines = crate::endpoint::machines();
    match serde_json::to_string(&machines) {
        Ok(text) => string_or_null(Some(text)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Adds a machine, or replaces the one with `id`.
///
/// Returns the id on success, or null with the reason in `hx_machine_error`.
///
/// # Safety
/// Every non-null pointer must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_machine_save(
    id: *const c_char,
    label: *const c_char,
    target: *const c_char,
    session: *const c_char,
    enabled: bool,
) -> *mut c_char {
    let read = |pointer: *const c_char| -> Option<String> {
        if pointer.is_null() {
            return None;
        }
        CStr::from_ptr(pointer).to_str().ok().map(str::to_owned)
    };
    let (Some(label), Some(target)) = (read(label), read(target)) else {
        *LAST_MACHINE_ERROR().lock().unwrap() = Some("invalid text".into());
        return std::ptr::null_mut();
    };
    let session = read(session).unwrap_or_default();

    match crate::endpoint::save_machine(
        read(id).as_deref(),
        &label,
        &target,
        &session,
        enabled,
    ) {
        Ok(saved) => string_or_null(Some(saved)),
        Err(reason) => {
            *LAST_MACHINE_ERROR().lock().unwrap() = Some(reason);
            std::ptr::null_mut()
        }
    }
}

/// Removes a machine.
///
/// # Safety
/// `id` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn hx_machine_remove(id: *const c_char) -> bool {
    if id.is_null() {
        return false;
    }
    let Ok(id) = CStr::from_ptr(id).to_str() else {
        return false;
    };
    match crate::endpoint::remove_machine(id) {
        Ok(()) => true,
        Err(reason) => {
            *LAST_MACHINE_ERROR().lock().unwrap() = Some(reason);
            false
        }
    }
}

/// Why the last machine edit failed.
///
/// # Safety
/// The returned pointer must be released with `hx_string_free`.
#[no_mangle]
pub unsafe extern "C" fn hx_machine_error() -> *mut c_char {
    match LAST_MACHINE_ERROR().lock().unwrap().take() {
        Some(reason) => string_or_null(Some(reason)),
        None => std::ptr::null_mut(),
    }
}
