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
        host_focused: AtomicBool::new(false),
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

/// The focus that follows an activation, which the server will only accept
/// once this client is the active one.
fn focus_after_activation(message: &ClientMessage) -> bool {
    let ClientMessage::ClientShellFocus { focused } = message else {
        panic!("activation must be followed by the window's focus, got {message:?}");
    };
    *focused
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
    shared.host_focused.store(true, Ordering::Release);
    assert!(apply_surface_state(&shared, &tx));
    assert_eq!(surface_request(&rx.try_recv().unwrap()), ("boot-1".into(), true));
    // The server ignores a focus from a client it does not consider active,
    // so an activation deferred until a boot id arrives has to say it then.
    assert!(focus_after_activation(&rx.try_recv().unwrap()));
}

/// Becoming active is the only moment the server will listen to this client
/// about its focus, so it is the moment to say so.
///
/// Switching to a machine sent the surface request and a resize and nothing
/// else, and whatever focus had been sent while it sat in the background was
/// dropped without a word — so a program that reports focus stayed unfocused
/// until the app was clicked away from and back.
#[test]
fn activation_announces_the_windows_focus() {
    let shared = shared();
    let (tx, rx) = std::sync::mpsc::channel();
    *shared.boot_id.lock().unwrap() = Some("boot-1".into());
    shared.host_focused.store(true, Ordering::Release);

    shared.desired_surface.store(true, Ordering::Release);
    assert!(apply_surface_state(&shared, &tx));

    assert_eq!(surface_request(&rx.try_recv().unwrap()).1, true);
    assert!(focus_after_activation(&rx.try_recv().unwrap()), "activation said nothing about focus");
}

/// And it says the truth: a window that has lost focus must not claim it on
/// the way in.
#[test]
fn activation_does_not_claim_focus_the_window_lacks() {
    let shared = shared();
    let (tx, rx) = std::sync::mpsc::channel();
    *shared.boot_id.lock().unwrap() = Some("boot-1".into());
    shared.host_focused.store(false, Ordering::Release);

    shared.desired_surface.store(true, Ordering::Release);
    assert!(apply_surface_state(&shared, &tx));
    let _ = rx.try_recv().unwrap();
    assert!(!focus_after_activation(&rx.try_recv().unwrap()));
}

/// Going *in*active says nothing: the server has stopped listening to this
/// client anyway, and the next activation is what re-establishes it.
#[test]
fn deactivation_says_nothing_about_focus() {
    let shared = shared();
    let (tx, rx) = std::sync::mpsc::channel();
    *shared.boot_id.lock().unwrap() = Some("boot-1".into());
    shared.desired_surface.store(true, Ordering::Release);
    shared.applied_surface.store(true, Ordering::Release);

    shared.desired_surface.store(false, Ordering::Release);
    assert!(apply_surface_state(&shared, &tx));
    let _ = rx.try_recv().unwrap();
    assert!(rx.try_recv().is_err(), "deactivation volunteered a focus");
}

#[test]
fn surface_state_is_not_resent_once_applied() {
    let shared = shared();
    let (tx, rx) = std::sync::mpsc::channel();
    *shared.boot_id.lock().unwrap() = Some("boot-1".into());

    shared.desired_surface.store(true, Ordering::Release);
    assert!(apply_surface_state(&shared, &tx));
    assert!(rx.try_recv().is_ok(), "the surface request");
    assert!(rx.try_recv().is_ok(), "the focus that follows an activation");

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
    // The focus that accompanies every activation.
    let _ = rx.try_recv().unwrap();

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
    // And told the focus too: a new boot has never heard it.
    assert!(focus_after_activation(&rx.try_recv().unwrap()) == false);
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
