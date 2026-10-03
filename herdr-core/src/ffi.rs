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

use crate::client::default_socket_path;
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
    /// Index into HxGrid.hyperlinks; u32::MAX means no link.
    pub hyperlink: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxHyperlink {
    pub bytes: *const u8,
    pub len: usize,
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
    pub hyperlinks: *const HxHyperlink,
    pub hyperlink_count: usize,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_visible: bool,
    pub cursor_shape: u8,
    /// Bumped on every committed surface so the renderer can skip idle frames.
    ///
    /// Counted locally and never reset. Not the server's surface revision:
    /// that belongs to one connection and starts again at 1 on the next, so a
    /// renderer keying on it holds a dead connection's output after a
    /// reconnect.
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
    /// Legacy patches carry cells but no table; the server falls back to a
    /// complete surface when a patch intersects linked cells.
    link_targets: Vec<String>,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    /// The server's revision for this surface, which is what a patch names as
    /// its base. It belongs to one connection and starts again at 1 on the
    /// next, so it says whether a patch fits — not whether what is on screen
    /// is still current.
    revision: u64,
    /// What is on screen, counted locally and never reset.
    ///
    /// The renderer needs to know that the picture changed, and after a
    /// reconnect the wire revision cannot tell it: a fresh connection's first
    /// surface is revision 1, the same number the last one left behind, so
    /// equal revisions meant "nothing to copy" and the previous machine's
    /// output stayed up until something happened to arrive at revision 2.
    stamp: u64,
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
        self.link_targets = frame.frame.hyperlinks.clone();
        self.revision = frame.surface_revision;
        self.set_cursor(frame.frame.cursor.as_ref());
        self.replace_panes(&frame.panes);
        self.placements = assets.ingest(&frame.graphics);
        self.stamp = self.stamp.wrapping_add(1);
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
        // Unconditionally: the field is the final cursor, so None is an answer
        // — there is not one — rather than nothing to say. Applying it only
        // when present left the last cursor drawn where it had been.
        self.set_cursor(patch.cursor.as_ref());
        self.revision = patch.surface_revision;
        self.stamp = self.stamp.wrapping_add(1);
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
                hyperlink: cell
                    .hyperlink
                    .filter(|index| (*index as usize) < self.link_targets.len())
                    .unwrap_or(u32::MAX),
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
    /// Set when the far side answered but has no herdr on it, which is a
    /// failure with an answer rather than one to only report.
    needs_install: AtomicBool,
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
    fn new(geometry: Geometry, surface_active: bool) -> Self {
        Self {
            grid: Mutex::new(Grid::default()),
            boot_id: Mutex::new(None),
            desired_surface: AtomicBool::new(surface_active),
            applied_surface: AtomicBool::new(surface_active),
            geometry: Mutex::new(geometry),
            resync_pending: AtomicBool::new(false),
            snapshot_json: Mutex::new(None),
            needs_install: AtomicBool::new(false),
            error: Mutex::new(None),
            events: Mutex::new(std::collections::VecDeque::new()),
            assets: Mutex::new(AssetCache::default()),
            connected: AtomicBool::new(false),
        }
    }

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

/// How long to wait before a second attempt, and the ceiling the wait climbs
/// to. Named because the tests assert against both ends of that range.
const FIRST_BACKOFF: std::time::Duration = std::time::Duration::from_millis(250);
const LONGEST_BACKOFF: std::time::Duration = std::time::Duration::from_secs(10);

/// A one-way stop signal for an endpoint's threads.
///
/// A flag alone would not do. The reconnect loop spends most of a failed
/// endpoint's life asleep in its backoff and the rest of it parked in a
/// blocking read, and disposal can afford to wait for neither.
#[derive(Default)]
struct Halt {
    state: Mutex<HaltState>,
    woken: std::sync::Condvar,
}

/// Both halves of stopping under one lock.
///
/// Held together rather than separately because a connection begun a moment
/// before disposal would otherwise publish its interrupt just after disposal
/// looked for one, and then block in a read with nothing left to break it.
#[derive(Default)]
struct HaltState {
    stopped: bool,
    interrupt: Option<crate::endpoint::Interrupt>,
    /// Advanced by every `nudge`.
    ///
    /// A generation rather than a flag because a flag has to be consumed, and
    /// whoever consumes it can be looking the other way when it is set. Two
    /// windows did exactly that: a nudge between a transport being built and
    /// being armed found nothing to interrupt and was dropped, and a nudge
    /// arriving while an attempt was still failing had no waiter to notify and
    /// was then slept straight through. Nothing reads this destructively, so
    /// there is no moment at which a wake can be missed — an attempt simply
    /// carries the generation it began at, and is stale whenever that no
    /// longer matches.
    generation: u64,
}

/// Why a wait between attempts ended.
#[derive(PartialEq, Eq, Debug)]
enum Rested {
    /// The wait ran its course; the machine is still not answering.
    Elapsed,
    /// A nudge arrived, or had already arrived. Try again now.
    Woken,
    /// The endpoint is being disposed of; the loop ends.
    Stopped,
}

impl Halt {
    /// The generation an attempt is about to begin at.
    fn generation(&self) -> u64 {
        self.state.lock().unwrap().generation
    }

    /// Takes the means to break the connection now being made, or refuses it.
    ///
    /// Refused when the endpoint is being disposed of, and — the reason
    /// `began` is here — when a nudge has landed since this attempt started.
    /// That transport was built over the path the nudge condemned, so arming
    /// it would park the loop in a read on a connection already known to be
    /// dead, with nothing left pending to break it out. Refusing makes
    /// `attach_interruptible` abandon the attempt, which is what lets the next
    /// one start from the woken generation.
    fn arm(&self, began: u64, interrupt: crate::endpoint::Interrupt) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.stopped || state.generation != began {
            return false;
        }
        state.interrupt = Some(interrupt);
        true
    }

    /// Forgets a connection that has ended on its own.
    fn disarm(&self) {
        self.state.lock().unwrap().interrupt = None;
    }

    fn stop(&self) {
        let interrupt = {
            let mut state = self.state.lock().unwrap();
            state.stopped = true;
            state.interrupt.take()
        };
        self.woken.notify_all();
        if let Some(interrupt) = interrupt {
            interrupt.wake();
        }
    }

    /// Condemns whatever connection this endpoint has and starts again now.
    ///
    /// Unlike `stop`, the endpoint survives. Advancing the generation is what
    /// makes this durable: it is not waiting for anyone to be listening, so an
    /// attempt in flight is refused when it tries to arm, and a loop about to
    /// wait finds the wake already there. Breaking the live connection is the
    /// other half, and only possible when there is one to break.
    ///
    /// See `hx_reattach_remotes` for when this is the right thing to do.
    fn nudge(&self) {
        let interrupt = {
            let mut state = self.state.lock().unwrap();
            if state.stopped {
                return;
            }
            state.generation += 1;
            state.interrupt.take()
        };
        self.woken.notify_all();
        if let Some(interrupt) = interrupt {
            interrupt.wake();
        }
    }

    fn stopped(&self) -> bool {
        self.state.lock().unwrap().stopped
    }

    /// Waits up to `duration` before the next attempt, or no time at all if
    /// this endpoint has already been stopped or woken.
    ///
    /// `began` is the generation the attempt that just ended started at, so a
    /// nudge that landed any time during it counts — including before there
    /// was a waiter here to notify. Checking that in the predicate rather than
    /// after the wait is the whole point: a wake used to be able to arrive
    /// while an attempt was still failing and then be slept straight through,
    /// for the whole of `LONGEST_BACKOFF`.
    fn rest(&self, duration: std::time::Duration, began: u64) -> Rested {
        let state = self.state.lock().unwrap();
        // Evaluates the predicate before waiting at all, and re-evaluates it
        // against the original deadline, so neither a wake already in hand nor
        // a spurious wakeup is mishandled.
        let (state, _) = self
            .woken
            .wait_timeout_while(state, duration, |state| {
                !state.stopped && state.generation == began
            })
            .unwrap();
        if state.stopped {
            Rested::Stopped
        } else if state.generation == began {
            Rested::Elapsed
        } else {
            Rested::Woken
        }
    }
}

/// One attached machine.
struct EndpointState {
    endpoint: crate::endpoint::Endpoint,
    shared: Arc<Shared>,
    /// One queue per endpoint, so sending does not block on a write and a
    /// slow machine cannot hold up the others.
    ///
    /// Not a buffer that survives a disconnection: what reaches a server that
    /// is not there is decided by `Outbound`, which keeps state and drops
    /// actions. See its `remember`.
    outbound: std::sync::mpsc::Sender<ClientMessage>,
    status: Arc<std::sync::atomic::AtomicU8>,
    /// How many times this endpoint has attached, counting the first.
    ///
    /// Monotonic because a status cannot answer "did it reconnect?": a drop
    /// and a reattach that both land between two samples leave the status
    /// exactly as it was, and a probe reading `online` either side of a wake
    /// learns nothing. A number that only climbs cannot be missed.
    attachments: Arc<std::sync::atomic::AtomicU64>,
    /// Stops the reconnect loop, wakes it out of its backoff and breaks it out
    /// of a blocking read.
    halt: Arc<Halt>,
    /// The live connection's write half, so disposal can close it.
    writer: Arc<Mutex<Outbound>>,
    /// The reconnect thread and the writer thread, joined on disposal.
    workers: Vec<std::thread::JoinHandle<()>>,
}

/// Ends an endpoint rather than abandoning it.
///
/// Without this, freeing a session left every connection it had running: the
/// reconnect loop kept its socket, its thread and its ssh process, and brought
/// them back the moment the far side dropped. Switching machines a few times
/// was enough to accumulate clients nothing could see or stop.
impl Drop for EndpointState {
    fn drop(&mut self) {
        self.halt.stop();
        // The writer thread ends when the last sender goes; ours is one of
        // them, and there is no way to drop a field in place but to swap it.
        let (unused, _) = std::sync::mpsc::channel();
        drop(std::mem::replace(&mut self.outbound, unused));
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
        // The read half died with the thread that held it; this is the write
        // half, and dropping it is what lets ChildGuard reap an ssh child.
        self.writer.lock().unwrap().writer = None;
    }
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
    front_hyperlinks: Vec<HxHyperlink>,
    /// Image bytes copied out for the caller, for the same reason.
    front_asset: Vec<u8>,
}

/// Ends every endpoint before the session's own handles go.
///
/// The order is the point. `outbound` is a clone of the active endpoint's
/// sender, and that endpoint cannot finish shutting down while a sender it
/// owns is still held — so this is explicit rather than left to whatever order
/// the fields happen to be declared in.
impl Drop for HxSession {
    fn drop(&mut self) {
        let (unused, _) = std::sync::mpsc::channel();
        drop(std::mem::replace(&mut self.outbound, unused));
        self.endpoints.clear();
    }
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
        self.front_hyperlinks.clear();
    }
}

/// Connects to every endpoint: the local server and each saved SSH machine.
///
/// Returns as soon as the endpoints exist, without waiting for any of them.
/// Reaching a machine over ssh can take seconds, and the window should be up
/// and showing local work long before that resolves.
///
/// `socket_path` is the local server's client socket — a herdr session is a
/// socket and nothing more, so choosing one is choosing this path. Null means
/// whatever `hx_default_socket_path` would say, which is what honours
/// `HERDR_SOCKET_PATH` and friends for a client that has not picked a session.
/// A machine reached over ssh has its own session, named in herdr's catalog,
/// and is unaffected — `attach_machines` decides only whether it is attached at
/// all, since a machine's session has nothing to do with the local one.
///
/// # Safety
/// The returned pointer must be released with `hx_session_free`.
#[no_mangle]
pub unsafe extern "C" fn hx_session_connect(
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    socket_path: *const c_char,
    attach_machines: bool,
) -> *mut HxSession {
    let socket = match socket_path.as_ref() {
        None => default_socket_path(),
        Some(path) => match CStr::from_ptr(path).to_str() {
            Ok(path) if !path.is_empty() => std::path::PathBuf::from(path),
            _ => default_socket_path(),
        },
    };
    let discovered = if attach_machines {
        crate::endpoint::discover()
    } else {
        vec![crate::endpoint::local()]
    };
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
            socket.clone(),
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
        front_hyperlinks: Vec::new(),
        front_asset: Vec::new(),
    }))
}

/// The hello for one attachment, built from what is true right now.
///
/// Not from what was true at startup. The window gets resized and machines get
/// switched between while an endpoint is away, and a hello carrying the values
/// it was first given asks the server to compose a surface for a window that is
/// no longer that size — or for a machine the user has since switched to, as an
/// inactive one.
fn attach_hello(shared: &Shared) -> herdr_protocol::protocol::endpoint::EndpointClientHello {
    let geometry = *shared.geometry.lock().unwrap();
    crate::client::hello_with_surface(
        geometry.cols,
        geometry.rows,
        geometry.cell_width_px,
        geometry.cell_height_px,
        shared.desired_surface.load(Ordering::Acquire),
    )
}

/// Resets the bookkeeping that belongs to a connection rather than to an
/// endpoint, now that there is a new one.
///
/// The server tracks surface state per connection and knows only what this
/// hello just told it, so `applied_surface` describes the hello — not whatever
/// the previous connection had been asked for. Leaving it stale is what could
/// leave a switched-to machine composing nothing: the two already agreed, so
/// nothing was ever sent.
fn begin_attachment(shared: &Shared, announced_surface: bool) {
    shared
        .applied_surface
        .store(announced_surface, Ordering::Release);
    // A resync asked of the connection that just died will never be answered.
    shared.resync_pending.store(false, Ordering::Release);
}

/// The write half, and the messages that must outlive not having one.
///
/// Outbound messages are queued before the connection is up, but the queue
/// alone is not enough: the writer thread used to dequeue while there was no
/// writer and drop what it found, so anything sent during a handshake — or
/// between a connection dying and the next one — was silently discarded.
///
/// Two kinds of message, and only one of them survives. Input and endpoint
/// requests are actions, and a keystroke meant for a machine that went away
/// must not arrive minutes later in whatever is on screen by then; those are
/// dropped, deliberately. Geometry and focus are not actions but descriptions
/// of this client, which the server holds per connection — so dropping one
/// leaves the two disagreeing until something else happens to change it. A
/// window resized while the welcome was in flight rendered at the old size,
/// and an unsent focus left this client unpromoted, which silently discards
/// its host theme.
#[derive(Default)]
struct Outbound {
    writer: Option<crate::endpoint::WriteHalf>,
    resize: Option<ClientMessage>,
    focus: Option<ClientMessage>,
}

impl Outbound {
    /// Keeps the newest message that *describes* this client, and ignores one
    /// that merely asks for something.
    ///
    /// State, not a queue. A resize or a focus change says what the client is
    /// rather than what it wants done, so only the latest matters — and it
    /// goes on mattering after it has been sent, because the server tracks
    /// both per connection and a reconnect starts it knowing neither.
    ///
    /// Remembering only a *failed* write was the bug: a client that had
    /// successfully said "I am focused" had nothing left to say after
    /// reconnecting. The old connection going away makes the server report
    /// focus lost, and only `ClientShellFocus(true)` takes it back — nothing
    /// in the handshake carries focus — so a program that reports focus sat
    /// unfocused until somebody happened to click away and back.
    fn remember(&mut self, message: &ClientMessage) {
        match message {
            ClientMessage::ClientShellResize { .. } => self.resize = Some(message.clone()),
            ClientMessage::ClientShellFocus { .. } => self.focus = Some(message.clone()),
            _ => {}
        }
    }

    /// Writes one message, keeping whatever it said about this client.
    fn write(&mut self, message: ClientMessage) {
        self.remember(&message);
        let Some(writer) = self.writer.as_mut() else {
            // Nothing to write to. Anything describing the client is now held
            // above and goes out on the next attach; anything else is an
            // action with no connection to perform it, and is dropped.
            return;
        };
        if crate::protocol::write_message(writer, &message).is_err() || writer.flush().is_err() {
            // The connection went away; the endpoint thread will install a new
            // writer when it reconnects.
            self.writer = None;
        }
    }

    /// Installs a new writer and brings it up to date on this client.
    ///
    /// Before anything queued behind it: the server should learn this client's
    /// size and focus in the same state the hello described, not after a
    /// keystroke has already been acted on at the wrong geometry.
    ///
    /// Cloned rather than taken, because this is the client's current state
    /// and the next reconnect needs it just as much as this one did.
    fn attach(&mut self, writer: Option<crate::endpoint::WriteHalf>) {
        self.writer = writer;
        for message in [self.resize.clone(), self.focus.clone()].into_iter().flatten() {
            self.write(message);
        }
    }
}

/// Starts one endpoint's connection and receive loop on its own thread.
fn spawn_endpoint(
    endpoint: crate::endpoint::Endpoint,
    surface_active: bool,
    geometry: Geometry,
    socket: std::path::PathBuf,
) -> EndpointState {
    let shared = Arc::new(Shared::new(geometry, surface_active));
    let status = Arc::new(std::sync::atomic::AtomicU8::new(HX_ENDPOINT_CONNECTING));
    let attachments = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let halt = Arc::new(Halt::default());
    let (tx, rx) = std::sync::mpsc::channel::<ClientMessage>();

    // Everything outbound goes through one `Outbound`, which survives
    // reconnects and holds this client's state across them. What it does with
    // a message sent while there is no connection is its own policy, stated
    // there — keystrokes for a machine that has gone away are dropped, not
    // banked, because a burst of them replayed minutes later is worse than
    // nothing.
    let outbound = Arc::new(Mutex::new(Outbound::default()));
    let writer_slot = Arc::clone(&outbound);
    let writer_thread = std::thread::spawn(move || {
        for message in rx {
            writer_slot.lock().unwrap().write(message);
        }
    });

    let thread_shared = Arc::clone(&shared);
    let thread_status = Arc::clone(&status);
    let thread_attachments = Arc::clone(&attachments);
    let thread_endpoint = endpoint.clone();
    let thread_outbound = tx.clone();
    let thread_halt = Arc::clone(&halt);
    let writer_for_loop = Arc::clone(&outbound);
    let connect_thread = std::thread::spawn(move || {
        let mut backoff = FIRST_BACKOFF;

        while !thread_halt.stopped() {
            // Read before anything slow starts, so everything this attempt
            // does can be recognised afterwards as belonging to it. A nudge
            // from here on makes the attempt stale, whether it has reached
            // the point of arming a transport or not.
            let began = thread_halt.generation();
            let hello = attach_hello(&thread_shared);

            match crate::client::EndpointConnection::attach_interruptible(
                &thread_endpoint,
                &socket,
                &hello,
                &|interrupt| thread_halt.arm(began, interrupt),
                &|| thread_halt.stopped(),
            ) {
                Ok(mut conn) => {
                    writer_for_loop.lock().unwrap().attach(conn.take_writer());
                    begin_attachment(&thread_shared, hello.surface_active);
                    thread_shared.connected.store(true, Ordering::Release);
                    thread_status.store(HX_ENDPOINT_ONLINE, Ordering::Release);
                    thread_attachments.fetch_add(1, Ordering::Release);
                    *thread_shared.error.lock().unwrap() = None;
                    thread_shared.needs_install.store(false, Ordering::Release);
                    backoff = FIRST_BACKOFF;

                    // Catches a switch that landed while the handshake was in
                    // flight, and so is not described by the hello.
                    apply_surface_state(&thread_shared, &thread_outbound);

                    receive_loop(
                        conn,
                        Arc::clone(&thread_shared),
                        Arc::clone(&thread_status),
                        thread_outbound.clone(),
                    );
                    writer_for_loop.lock().unwrap().writer = None;
                    thread_halt.disarm();
                }
                Err(err) => {
                    // No label: whatever shows this already knows which
                    // machine it is asking about.
                    let message = err.to_string();
                    // A nudge abandons an attempt on purpose, and the message
                    // it leaves is ours — "endpoint was closed while
                    // connecting". The machine never spoke, so it must not be
                    // the one the sidebar blames for a wake we caused.
                    if thread_halt.generation() == began {
                        // Only ever set here, never cleared: the first attempt
                        // can fail before ssh's stderr has been read, giving a
                        // bare "unexpected end of stream", and a machine that
                        // has told us herdr is missing has not gained it by
                        // failing more vaguely the next time. Connecting
                        // clears it.
                        if herdr_is_missing(&thread_endpoint, &message) {
                            thread_shared.needs_install.store(true, Ordering::Release);
                        }
                        *thread_shared.error.lock().unwrap() =
                            Some(explain_attach_failure(&thread_endpoint, &message));
                    }
                    thread_status.store(HX_ENDPOINT_OFFLINE, Ordering::Release);
                    thread_halt.disarm();
                }
            }

            // Each endpoint reconnects on its own. A machine that is asleep
            // must not stop the others from working, which is what a
            // session-wide retry would do.
            match thread_halt.rest(backoff, began) {
                Rested::Stopped => break,
                // The last attempt ended because we condemned it, not because
                // the machine refused us, so the climb starts over.
                Rested::Woken => backoff = FIRST_BACKOFF,
                Rested::Elapsed => backoff = (backoff * 2).min(LONGEST_BACKOFF),
            }
            thread_status.store(HX_ENDPOINT_CONNECTING, Ordering::Release);
        }

        thread_shared.connected.store(false, Ordering::Release);
        thread_status.store(HX_ENDPOINT_OFFLINE, Ordering::Release);
    });

    EndpointState {
        endpoint,
        shared,
        outbound: tx,
        status,
        attachments,
        halt,
        writer: outbound,
        workers: vec![connect_thread, writer_thread],
    }
}

/// Turns a transport failure into something a reader can act on.
///
/// herdr installs itself on a machine when you attach with `herdr --remote`,
/// after asking; it is not something that happens because a client tried to
/// connect. So a machine without it is a machine that needs that command run
/// once, and saying so is more use than passing on the shell's own wording.
fn explain_attach_failure(endpoint: &crate::endpoint::Endpoint, message: &str) -> String {
    if herdr_is_missing(endpoint, message) {
        return "herdr is not installed on this machine".to_owned();
    }
    message.to_owned()
}

/// Whether the far side answered but had no herdr to run.
///
/// ssh reached the machine and its shell replied; the only thing wrong is the
/// binary. That is a failure with a remedy, so it is worth telling apart from
/// one that just has to be reported.
fn herdr_is_missing(endpoint: &crate::endpoint::Endpoint, message: &str) -> bool {
    matches!(endpoint.kind, crate::endpoint::EndpointKind::Ssh { .. })
        && (message.contains("command not found")
            || message.contains("No such file or directory")
            || message.contains("not found"))
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

/// How many times this endpoint has attached, counting the first.
///
/// For telling a reconnect that happened from one that did not. Status cannot:
/// a drop and a reattach between two samples leave it reading `online` both
/// times, which is what a wake that works and a wake that does nothing have in
/// common.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_attachments(session: *const HxSession, index: usize) -> u64 {
    session
        .as_ref()
        .and_then(|s| s.endpoints.get(index))
        .map_or(0, |e| e.attachments.load(Ordering::Acquire))
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

/// Drops one endpoint's connection and reattaches, without waiting for the
/// transport to work out that it is dead.
///
/// The reconnect loop is already there and already does the work; this only
/// says "now". Separate from the policy above it so both halves can be
/// measured: this one against a mock server, which is a unix socket and so
/// never the kind of endpoint the wake policy touches.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_reattach(session: *const HxSession, index: usize) -> bool {
    session
        .as_ref()
        .and_then(|s| s.endpoints.get(index))
        .map(|endpoint| endpoint.halt.nudge())
        .is_some()
}

/// Drops every remote connection and reattaches, for a caller that knows the
/// connections are stale — a wake from sleep being the one that does.
///
/// Nothing on the wire says a path has died, so without being told, the only
/// thing that notices is the transport's own keepalive timeout; `start_ssh`
/// carries how long that is, and `ARCHITECTURE.md` why waiting for it is not
/// good enough.
///
/// Local endpoints are left alone. A unix socket lives entirely in this
/// machine's kernel, so it comes back from sleep exactly as it went in, and
/// dropping a connection that works to prove it would only cost a resend.
///
/// Returns how many endpoints were asked to reattach.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_reattach_remotes(session: *const HxSession) -> usize {
    let Some(session) = session.as_ref() else {
        return 0;
    };
    session
        .endpoints
        .iter()
        .filter(|endpoint| !matches!(endpoint.endpoint.kind, crate::endpoint::EndpointKind::Local))
        .map(|endpoint| endpoint.halt.nudge())
        .count()
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

/// The client socket a null `socket_path` would connect to.
///
/// The app needs this to say which session it is in: the answer depends on
/// `HERDR_SOCKET_PATH`, `HERDR_CLIENT_SOCKET_PATH` and the config directory,
/// and a second implementation of that order in Swift would be a second thing
/// to get wrong. Caller frees with `hx_string_free`.
#[no_mangle]
pub extern "C" fn hx_default_socket_path() -> *mut c_char {
    string_or_null(Some(
        default_socket_path().to_string_lossy().into_owned(),
    ))
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
        if back.stamp != session.front.stamp || session.front.cells.is_empty() {
            session.front.clone_from(&back);
            // The borrowed slices must point into the front clone, not the
            // receive thread's grid (which may be replaced at any moment).
            session.front_hyperlinks = session
                .front
                .link_targets
                .iter()
                .map(|target| HxHyperlink {
                    bytes: target.as_ptr(),
                    len: target.len(),
                })
                .collect();
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
            hyperlinks: session.front_hyperlinks.as_ptr(),
            hyperlink_count: session.front_hyperlinks.len(),
            cursor_x: front.cursor_x,
            cursor_y: front.cursor_y,
            cursor_visible: front.cursor_visible,
            cursor_shape: front.cursor_shape,
            revision: front.stamp,
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

/// Whether a machine is reachable but has no herdr installed.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_needs_install(
    session: *const HxSession,
    index: usize,
) -> bool {
    let Some(session) = session.as_ref() else {
        return false;
    };
    session
        .endpoints
        .get(index)
        .is_some_and(|endpoint| endpoint.shared.needs_install.load(Ordering::Acquire))
}

/// Tells every server whether this window is the one being looked at.
///
/// herdr keeps one foreground client per session and only listens to that one
/// for the host theme — so a client that never says it has focus is only
/// promoted as a side effect of typing, and a theme change made without typing
/// first is dropped without a word.
///
/// # Safety
/// `session` must be live.
#[no_mangle]
pub unsafe extern "C" fn hx_set_focus(session: *const HxSession, focused: bool) -> bool {
    let Some(session) = session.as_ref() else {
        return false;
    };
    let mut sent = false;
    for endpoint in &session.endpoints {
        sent |= endpoint
            .outbound
            .send(ClientMessage::ClientShellFocus { focused })
            .is_ok();
    }
    sent
}

/// Why one endpoint is not connected, if it has said.
///
/// Read rather than taken: this is what a machine's row shows for as long as it
/// is failing, and draining it would make the reason flicker past once and
/// leave "not connected" standing on its own.
///
/// # Safety
/// `session` must be live. The returned pointer must be released with
/// `hx_string_free`.
#[no_mangle]
pub unsafe extern "C" fn hx_endpoint_error(
    session: *const HxSession,
    index: usize,
) -> *mut c_char {
    let Some(session) = session.as_ref() else {
        return std::ptr::null_mut();
    };
    string_or_null(
        session
            .endpoints
            .get(index)
            .and_then(|endpoint| endpoint.shared.error.lock().unwrap().clone()),
    )
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
mod halt_tests {
    use super::*;

    /// A transport whose only job is to be armed, and to say whether anything
    /// ever broke it.
    ///
    /// `Interrupt::Local` wants a real socket pair — the point of it is that
    /// shutting one half down returns the other half's blocked read — so these
    /// use one rather than a stub. Whether the peer saw the shutdown is the
    /// honest reading of "was this connection broken".
    fn socket_pair() -> (std::os::unix::net::UnixStream, std::os::unix::net::UnixStream) {
        let (near, far) = std::os::unix::net::UnixStream::pair().expect("socket pair");
        // Set now rather than when it is read, because waking an interrupt
        // drops it, and macOS refuses `setsockopt` on a socket whose peer has
        // closed — the very state these tests are trying to observe.
        far.set_read_timeout(Some(std::time::Duration::from_millis(250)))
            .expect("read timeout");
        (near, far)
    }

    /// Whether the connection was broken, read from the far end rather than
    /// from our own record of having asked.
    fn was_broken(peer: &std::os::unix::net::UnixStream) -> bool {
        use std::io::Read;
        // A shutdown or closed half reads as end-of-stream; a live one has
        // nothing to say and times out instead.
        let mut byte = [0u8; 1];
        matches!((&mut { peer }).read(&mut byte), Ok(0))
    }

    /// The window that let a wake go missing: a nudge lands after the
    /// transport exists but before the loop has armed it.
    ///
    /// Nothing is there to interrupt, so the nudge used to be dropped on the
    /// floor and `arm` would then accept the condemned transport — leaving the
    /// loop parked in a read on a path already known to be dead, with nothing
    /// pending to break it out. Recovery fell back to ssh's keepalive timeout,
    /// which is the wait the nudge exists to skip.
    #[test]
    fn a_transport_built_before_a_nudge_is_refused_after_it() {
        let halt = Halt::default();
        let began = halt.generation();
        let (near, far) = socket_pair();

        halt.nudge();

        assert!(
            !halt.arm(began, crate::endpoint::Interrupt::Local(near)),
            "armed a transport the nudge had already condemned"
        );
        // Refusing is only useful because it is what makes the attempt give
        // up; an attempt that proceeded unarmed would be the same bug.
        assert_eq!(
            halt.rest(LONGEST_BACKOFF, began),
            Rested::Woken,
            "the refused attempt did not lead to a fresh one"
        );
        drop(far);
    }

    /// The same window, one step later: a nudge after the transport is armed
    /// has something to break, and must break it.
    #[test]
    fn a_nudge_breaks_a_transport_that_was_armed_in_time() {
        let halt = Halt::default();
        let began = halt.generation();
        let (near, far) = socket_pair();

        assert!(halt.arm(began, crate::endpoint::Interrupt::Local(near)));
        halt.nudge();

        assert!(
            was_broken(&far),
            "the live connection survived the nudge, so the read would not return"
        );
    }

    /// A wake that arrives while an attempt is still failing has no waiter to
    /// notify, and used to be slept through for the full backoff.
    #[test]
    fn a_wake_already_in_hand_is_not_slept_through() {
        let halt = Halt::default();
        let began = halt.generation();

        halt.nudge();

        let started = std::time::Instant::now();
        let rested = halt.rest(LONGEST_BACKOFF, began);
        let took = started.elapsed();

        assert_eq!(rested, Rested::Woken);
        assert!(
            took < std::time::Duration::from_millis(100),
            "waited {took:?} with a wake already in hand; the ceiling is \
             {LONGEST_BACKOFF:?} and that is what used to be paid"
        );
    }

    /// And one that arrives during the wait still cuts it short.
    #[test]
    fn a_wake_during_the_wait_cuts_it_short() {
        let halt = std::sync::Arc::new(Halt::default());
        let began = halt.generation();

        let waker = std::sync::Arc::clone(&halt);
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(50));
            waker.nudge();
        });

        let started = std::time::Instant::now();
        assert_eq!(halt.rest(LONGEST_BACKOFF, began), Rested::Woken);
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
    }

    /// Without a nudge the wait is the wait, or the climb would never happen.
    #[test]
    fn an_undisturbed_wait_runs_its_course() {
        let halt = Halt::default();
        let began = halt.generation();

        let started = std::time::Instant::now();
        let rested = halt.rest(std::time::Duration::from_millis(200), began);
        let took = started.elapsed();

        assert_eq!(rested, Rested::Elapsed);
        assert!(
            took >= std::time::Duration::from_millis(150),
            "returned after {took:?}; a wait nothing interrupted came back early"
        );
    }

    /// Disposal outranks a wake, whichever order they arrive in: a nudged
    /// endpoint that is then freed must not come back.
    #[test]
    fn stopping_outranks_a_pending_wake() {
        let halt = Halt::default();
        let began = halt.generation();

        halt.nudge();
        halt.stop();

        assert_eq!(halt.rest(LONGEST_BACKOFF, began), Rested::Stopped);
        let (near, far) = socket_pair();
        assert!(
            !halt.arm(halt.generation(), crate::endpoint::Interrupt::Local(near)),
            "a stopped endpoint armed another transport"
        );
        drop(far);
    }

    /// Four wakes in a row are four reconnects, not one. A laptop opened four
    /// times is the ordinary case, and a generation that stopped moving — or a
    /// flag that stopped being noticed — would leave it offline.
    #[test]
    fn every_wake_counts_not_just_the_first() {
        let halt = Halt::default();
        let mut began = halt.generation();

        for round in 1..=4 {
            halt.nudge();
            assert_eq!(
                halt.rest(LONGEST_BACKOFF, began),
                Rested::Woken,
                "wake {round} was not acted on"
            );
            began = halt.generation();
            assert_eq!(began, round, "the generation stopped moving at {began}");
        }

        // And with no wake pending, the next wait is an ordinary one.
        assert_eq!(
            halt.rest(std::time::Duration::from_millis(50), began),
            Rested::Elapsed
        );
    }
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

    fn window(cols: u16, rows: u16) -> Geometry {
        Geometry {
            cols,
            rows,
            cell_width_px: 8,
            cell_height_px: 16,
        }
    }

    #[test]
    fn a_hello_describes_the_window_at_the_moment_it_is_built() {
        let shared = Shared::new(window(80, 24), true);

        // What a resize does while an endpoint is away.
        *shared.geometry.lock().unwrap() = window(132, 43);
        let hello = attach_hello(&shared);

        assert_eq!((hello.surface_size.cols, hello.surface_size.rows), (132, 43));
        assert!(hello.surface_active);
    }

    #[test]
    fn a_hello_describes_the_surface_state_wanted_now() {
        let shared = Shared::new(window(80, 24), true);

        // What switching to another machine does.
        shared.desired_surface.store(false, Ordering::Release);
        assert!(!attach_hello(&shared).surface_active);

        shared.desired_surface.store(true, Ordering::Release);
        assert!(attach_hello(&shared).surface_active);
    }

    #[test]
    fn a_new_attachment_forgets_what_the_last_one_was_told() {
        // Switched away from while offline: the endpoint wants no surface, and
        // the dead connection had been told so.
        let shared = Shared::new(window(80, 24), false);
        shared.applied_surface.store(false, Ordering::Release);

        // Then switched back to, still offline, so nothing could be sent.
        shared.desired_surface.store(true, Ordering::Release);

        let hello = attach_hello(&shared);
        assert!(hello.surface_active, "the hello must ask for the surface");
        begin_attachment(&shared, hello.surface_active);

        assert!(
            shared.applied_surface.load(Ordering::Acquire),
            "the hello is what the new server was told, so that is what is applied"
        );
    }

    #[test]
    fn a_new_attachment_drops_a_resync_the_old_one_never_answered() {
        let shared = Shared::new(window(80, 24), true);
        shared.resync_pending.store(true, Ordering::Release);

        begin_attachment(&shared, true);

        assert!(
            !shared.resync_pending.load(Ordering::Acquire),
            "a resync asked of a connection that died is never coming back, and \
             holding the flag suppresses the one this connection needs"
        );
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
    fn hyperlink_targets_follow_full_surfaces_and_legacy_patches() {
        let mut grid = Grid::default();
        let mut first = surface(1);
        first.frame.hyperlinks = vec!["https://first.example".into()];
        first.frame.cells[0].hyperlink = Some(0);
        install(&mut grid, &first);
        assert_eq!(grid.cells[0].hyperlink, 0);
        assert_eq!(grid.link_targets[0], "https://first.example");

        grid.apply_patch(&patch(1, 2, vec![PaneSurfacePatchRow {
            x: 1, y: 0, cells: vec![cell("B")],
        }]));
        assert_eq!(grid.cells[0].hyperlink, 0);
        assert_eq!(grid.link_targets[0], "https://first.example");

        let mut next = surface(3);
        next.frame.hyperlinks = vec!["https://second.example".into()];
        next.frame.cells[0].hyperlink = Some(0);
        next.frame.cells[1].hyperlink = Some(99);
        install(&mut grid, &next);
        assert_eq!(grid.link_targets[grid.cells[0].hyperlink as usize], "https://second.example");
        assert_eq!(grid.cells[1].hyperlink, u32::MAX);
        install(&mut grid, &surface(4));
        assert!(grid.link_targets.is_empty());
        assert_eq!(grid.cells[0].hyperlink, u32::MAX);
    }

    /// A session with no transport: enough to exercise the front buffer.
    fn detached_session(shared: &Arc<Shared>) -> HxSession {
        let (outbound, _rx) = std::sync::mpsc::channel();
        HxSession {
            endpoints: Vec::new(),
            active: 0,
            shared: Arc::clone(shared),
            outbound,
            geometry: Mutex::new(window(80, 24)),
            front: Grid::default(),
            front_hyperlinks: Vec::new(),
            front_asset: Vec::new(),
        }
    }

    fn acquired_text(session: &mut HxSession) -> String {
        let mut out = std::mem::MaybeUninit::<HxGrid>::uninit();
        assert!(unsafe { hx_grid_acquire(session, out.as_mut_ptr()) });
        let grid = unsafe { out.assume_init() };
        let glyphs = unsafe { std::slice::from_raw_parts(grid.glyphs, grid.glyph_bytes) };
        String::from_utf8_lossy(glyphs).into_owned()
    }

    /// Surface revisions belong to one connection and start again at 1 on the
    /// next, so the front buffer cannot use them to tell one machine's output
    /// from another's.
    #[test]
    fn a_reconnect_that_replays_revision_one_still_reaches_the_screen() {
        let shared = Arc::new(shared());
        let mut session = detached_session(&shared);

        let mut first = surface(1);
        first.frame.cells = vec![cell("A")];
        first.frame.width = 1;
        first.frame.height = 1;
        shared
            .grid
            .lock()
            .unwrap()
            .replace(&first, &mut AssetCache::default());
        assert_eq!(acquired_text(&mut session), "A");

        // The connection dropped and came back. The new server numbers its
        // first surface 1, exactly as the old one did.
        let mut second = surface(1);
        second.frame.cells = vec![cell("B")];
        second.frame.width = 1;
        second.frame.height = 1;
        shared
            .grid
            .lock()
            .unwrap()
            .replace(&second, &mut AssetCache::default());

        assert_eq!(
            acquired_text(&mut session),
            "B",
            "the front buffer kept the previous connection's surface"
        );
    }

    /// And the renderer above it has to see the change too.
    #[test]
    fn the_reported_revision_moves_when_the_picture_does() {
        let shared = Arc::new(shared());
        let mut session = detached_session(&shared);

        let mut first = surface(1);
        first.frame.cells = vec![cell("A")];
        first.frame.width = 1;
        first.frame.height = 1;
        shared
            .grid
            .lock()
            .unwrap()
            .replace(&first, &mut AssetCache::default());
        let mut out = std::mem::MaybeUninit::<HxGrid>::uninit();
        assert!(unsafe { hx_grid_acquire(&mut session, out.as_mut_ptr()) });
        let before = unsafe { out.assume_init() }.revision;

        let mut second = surface(1);
        second.frame.cells = vec![cell("B")];
        second.frame.width = 1;
        second.frame.height = 1;
        shared
            .grid
            .lock()
            .unwrap()
            .replace(&second, &mut AssetCache::default());
        let mut out = std::mem::MaybeUninit::<HxGrid>::uninit();
        assert!(unsafe { hx_grid_acquire(&mut session, out.as_mut_ptr()) });
        let after = unsafe { out.assume_init() }.revision;

        assert_ne!(before, after, "the renderer would skip this frame as idle");
    }

    fn test_welcome() -> ServerMessage {
        use herdr_protocol::protocol::endpoint::{
            EndpointServerWelcome, ENDPOINT_PROTOCOL_GENERATION, ENDPOINT_WELCOME_KIND,
            BLOB_CODEC_V1, INPUT_CODEC_V1, SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
        };
        let welcome = EndpointServerWelcome {
            generation: ENDPOINT_PROTOCOL_GENERATION,
            server_version: herdr_protocol::VENDORED_HERDR_VERSION.into(),
            snapshot_codec: SNAPSHOT_CODEC_V1.into(),
            surface_codec: SURFACE_CODEC_V1.into(),
            input_codec: INPUT_CODEC_V1.into(),
            blob_codec: BLOB_CODEC_V1.into(),
            methods: Vec::new(),
            capabilities: Vec::new(),
            error: None,
        };
        ServerMessage::EndpointControl {
            kind: ENDPOINT_WELCOME_KIND.into(),
            data: serde_json::to_string(&welcome).unwrap(),
        }
    }

    /// A resize that lands while the welcome is still in flight has no writer
    /// to go out on, and the server would otherwise keep rendering the size
    /// the hello described.
    #[test]
    fn geometry_and_focus_sent_before_the_writer_exists_are_not_lost() {
        let mut outbound = Outbound::default();
        outbound.write(ClientMessage::ClientShellResize {
            cell_width_px: 8,
            cell_height_px: 17,
            surface_size: herdr_protocol::protocol::ClientSurfaceSize { cols: 132, rows: 43 },
            pixel_mouse: true,
        });
        outbound.write(ClientMessage::ClientShellFocus { focused: true });

        assert!(outbound.resize.is_some(), "the resize was dropped");
        assert!(outbound.focus.is_some(), "the focus was dropped");

        // Only the latest of each is worth keeping: the window has one size.
        outbound.write(ClientMessage::ClientShellResize {
            cell_width_px: 8,
            cell_height_px: 17,
            surface_size: herdr_protocol::protocol::ClientSurfaceSize { cols: 100, rows: 30 },
            pixel_mouse: true,
        });
        let Some(ClientMessage::ClientShellResize { surface_size, .. }) = &outbound.resize else {
            panic!("expected a held resize");
        };
        assert_eq!((surface_size.cols, surface_size.rows), (100, 30));
    }

    /// The same thing over a real socket, with the welcome held back so the
    /// resize is guaranteed to arrive while there is no writer.
    #[test]
    fn a_resize_during_a_slow_handshake_reaches_the_server() {
        use std::os::unix::net::UnixListener;

        let path = std::env::temp_dir().join(format!(
            "herdx-handshake-{}-{:?}.sock",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind");
        let (welcomed, may_welcome) = std::sync::mpsc::channel::<()>();
        let (saw, seen) = std::sync::mpsc::channel::<ClientMessage>();

        std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
            let mut writer = std::io::BufWriter::new(stream);
            let _: ClientMessage =
                crate::protocol::read_message(&mut reader, herdr_protocol::protocol::MAX_FRAME_SIZE)
                    .expect("hello");
            // Slow server: the client resizes while this is still pending.
            may_welcome.recv().expect("go");
            crate::protocol::write_message(&mut writer, &test_welcome()).expect("welcome");
            writer.flush().unwrap();
            while let Ok(message) = crate::protocol::read_message::<_, ClientMessage>(
                &mut reader,
                herdr_protocol::protocol::MAX_FRAME_SIZE,
            ) {
                if saw.send(message).is_err() {
                    break;
                }
            }
        });

        let state = spawn_endpoint(
            crate::endpoint::Endpoint {
                id: "local".into(),
                label: "Local".into(),
                kind: crate::endpoint::EndpointKind::Local,
            },
            true,
            window(80, 24),
            path.clone(),
        );

        state
            .outbound
            .send(ClientMessage::ClientShellResize {
                cell_width_px: 8,
                cell_height_px: 17,
                surface_size: herdr_protocol::protocol::ClientSurfaceSize { cols: 132, rows: 43 },
                pixel_mouse: true,
            })
            .expect("queue the resize");

        // Wait until the writer thread has taken it and found no writer, so
        // this really is the case where it used to be thrown away.
        let held = std::time::Instant::now();
        while state.writer.lock().unwrap().resize.is_none() {
            assert!(held.elapsed() < std::time::Duration::from_secs(5), "never held");
            std::thread::yield_now();
        }

        welcomed.send(()).expect("let the welcome through");
        let message = seen
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the server never heard the resize");
        let ClientMessage::ClientShellResize { surface_size, .. } = message else {
            panic!("expected a resize, got {message:?}");
        };
        assert_eq!((surface_size.cols, surface_size.rows), (132, 43));

        drop(state);
        let _ = std::fs::remove_file(&path);
    }

    /// Input is not held. Replaying a keystroke into whatever is on screen
    /// minutes later is worse than losing it.
    #[test]
    fn input_sent_with_no_connection_is_dropped_rather_than_replayed() {
        let mut outbound = Outbound::default();
        outbound.write(ClientMessage::ClientShellFocus { focused: true });
        outbound.write(ClientMessage::ClientShellEndpointRequest {
            boot_id: "boot".into(),
            request: "{}".into(),
        });
        assert!(outbound.focus.is_some());
        // Nothing else is held, and the request is simply gone.
        assert!(outbound.resize.is_none());
    }

    /// `PaneSurfacePatch::cursor` is the final cursor, and None is an answer:
    /// it means there is not one. Applying it only when present left the last
    /// one drawn where it had been.
    #[test]
    fn a_patch_that_removes_the_cursor_removes_it() {
        let mut grid = Grid::default();
        install(&mut grid, &surface(1));
        assert!(grid.cursor_visible, "the fixture needs a cursor to remove");

        assert!(grid.apply_patch(&patch(
            1,
            2,
            vec![PaneSurfacePatchRow { x: 0, y: 0, cells: vec![cell("Z")] }]
        )));

        assert!(!grid.cursor_visible, "the removed cursor is still drawn");
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

    /// A report as the client builds one: already in the addressed pane's
    /// coordinates, and carrying that pane's size rather than the surface's.
    fn mouse(kind: u16, button: u8, lines: u16) -> HxMouseEvent {
        HxMouseEvent {
            kind,
            button,
            column: 4,
            row: 3,
            pixel_x: 40,
            pixel_y: 52,
            cols: 40,
            rows: 12,
            width_px: 360,
            height_px: 192,
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
            needs_install: AtomicBool::new(false),
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

    /// Panes running SGR pixel mouse need exact pixel geometry, and it has to
    /// be the *pane's*: the server hands this straight to that pane's
    /// emulator, so the surface's dimensions describe something that is not
    /// there. The position is the pane's for the same reason.
    #[test]
    fn mouse_message_carries_the_panes_own_geometry() {
        use herdr_protocol::protocol::{ClientMouseGeometry, ClientMousePosition, ClientPaneInputEvent};
        let kind = mouse_kind(HX_MOUSE_DOWN, HX_BUTTON_LEFT).unwrap();
        let message = mouse_message("p1", &mouse(HX_MOUSE_DOWN, HX_BUTTON_LEFT, 0), kind);

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
            Some(ClientMouseGeometry { cols: 40, rows: 12, width_px: 360, height_px: 192 }),
            "the whole surface's size was sent for one pane"
        );
        assert_eq!(*lines, 1, "a zero-row scroll should still move one row");
    }

    #[test]
    fn scroll_rows_are_preserved() {
        let kind = mouse_kind(HX_MOUSE_SCROLL_DOWN, HX_BUTTON_LEFT).unwrap();
        let message = mouse_message("p1", &mouse(HX_MOUSE_SCROLL_DOWN, HX_BUTTON_LEFT, 5), kind);
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

/// One mouse event, already in the addressed pane's coordinates.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HxMouseEvent {
    pub kind: u16,
    pub button: u8,
    /// Cell coordinates, relative to the addressed pane's inner origin.
    ///
    /// The server hands these to that pane's emulator without subtracting
    /// anything, so they have to arrive pane-local. They used to be surface
    /// coordinates, which told a pane halfway across the window that every
    /// click was halfway across the window.
    pub column: u16,
    pub row: u16,
    /// Pixel coordinates within the pane, for SGR pixel mouse.
    pub pixel_x: u32,
    pub pixel_y: u32,
    /// The pane's own size, which is what a program using pixel mouse scales
    /// against. The surface's described a pane that does not exist.
    pub cols: u16,
    pub rows: u16,
    pub width_px: u32,
    pub height_px: u32,
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

    session
        .outbound
        .send(mouse_message(pane_id, &event, kind))
        .is_ok()
}

/// Builds the wire message for one mouse report.
///
/// The geometry comes from the event rather than from the session: it has to
/// describe the pane being addressed, and only the caller knows which pane the
/// gesture belongs to.
fn mouse_message(
    pane_id: &str,
    event: &HxMouseEvent,
    kind: herdr_protocol::protocol::ClientMouseKind,
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
                cols: event.cols,
                rows: event.rows,
                width_px: event.width_px,
                height_px: event.height_px,
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
    // A catalog that cannot be read is reported rather than shown as no
    // machines: an empty list invites adding one, and adding one is what would
    // overwrite the file still holding them.
    let machines = match crate::endpoint::machines() {
        Ok(machines) => machines,
        Err(reason) => {
            *LAST_MACHINE_ERROR().lock().unwrap() = Some(reason);
            return std::ptr::null_mut();
        }
    };
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
