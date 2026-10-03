//! A herdr server that exists only to be connected to.
//!
//! Enough of one to answer a generation-1 handshake and then say nothing, which
//! is all it takes to ask the questions these tests ask: did that connection
//! close, and did another one arrive to replace it?
//!
//! Not a test itself — `tests/` compiles each file as its own binary, so this
//! is included by the ones that use it rather than built on its own.

#![allow(dead_code)]

use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use herdr_protocol::protocol::endpoint::{
    EndpointClientHello, EndpointServerWelcome, BLOB_CODEC_V1, ENDPOINT_PROTOCOL_GENERATION,
    ENDPOINT_WELCOME_KIND, INPUT_CODEC_V1, SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
};
use herdr_protocol::protocol::{
    read_message, write_message, ClientMessage, ServerMessage, MAX_FRAME_SIZE,
};

/// What one attachment told the server about itself, and what became of it.
#[derive(Clone, Debug)]
pub struct Attachment {
    pub hello: EndpointClientHello,
    /// Set once the client's end of this connection has gone.
    pub closed: bool,
    /// What the client said on this connection after the handshake, in order.
    ///
    /// Recorded because some of what a client has to tell a server is not in
    /// the hello: focus is not, and the server tracks it per connection, so
    /// "did the reconnect say it again" is a question only the stream can
    /// answer.
    pub messages: Vec<ClientMessage>,
}

#[derive(Default)]
struct Log {
    attachments: Vec<Attachment>,
    /// A handle on each connection, so a test can drop them the way a restarted
    /// server or a dying ssh would.
    live: Vec<UnixStream>,
}

pub struct MockServer {
    path: std::path::PathBuf,
    log: Arc<Mutex<Log>>,
    stopping: Arc<AtomicBool>,
    /// Held so the accept loop's listener can be shut down by dropping it.
    _listener: Arc<UnixListener>,
}

impl MockServer {
    /// Where this server listens.
    ///
    /// Short and bounded on purpose. A unix socket path is capped at
    /// `SUN_LEN` — 104 bytes on macOS — and the old name was the test's own
    /// description plus a pid plus a `ThreadId`, which grew with the number
    /// of tests in the binary. It fit here and did not on CI, where the
    /// temp directory is longer, so a release failed at `bind` with a message
    /// about nothing a reader of the test would recognise. Asking every
    /// caller to keep its name short was the first answer and it only moved
    /// the cliff.
    ///
    /// So: a counter rather than a thread id, six characters of the name for
    /// anything that leaks, and `/tmp` when even that will not fit.
    fn socket_path(name: &str) -> std::path::PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let short: String = name.chars().filter(|c| c.is_ascii_alphanumeric()).take(6).collect();
        let file = format!("hx-{short}-{}-{n}.sock", std::process::id());
        let candidate = std::env::temp_dir().join(&file);
        // 104 includes the trailing NUL, so leave room for it.
        if candidate.as_os_str().len() < 100 {
            candidate
        } else {
            std::path::PathBuf::from("/tmp").join(file)
        }
    }

    pub fn start(name: &str) -> Self {
        let path = Self::socket_path(name);
        let _ = std::fs::remove_file(&path);
        let listener = Arc::new(
            UnixListener::bind(&path)
                .unwrap_or_else(|e| panic!("bind mock socket at {}: {e}", path.display())),
        );

        let log = Arc::new(Mutex::new(Log::default()));
        let stopping = Arc::new(AtomicBool::new(false));

        let accept_listener = Arc::clone(&listener);
        let accept_log = Arc::clone(&log);
        let accept_stopping = Arc::clone(&stopping);
        std::thread::spawn(move || {
            for stream in accept_listener.incoming() {
                if accept_stopping.load(Ordering::Acquire) {
                    return;
                }
                let Ok(stream) = stream else { return };
                let log = Arc::clone(&accept_log);
                std::thread::spawn(move || serve(stream, log));
            }
        });

        Self {
            path,
            log,
            stopping,
            _listener: listener,
        }
    }

    pub fn socket(&self) -> &std::path::Path {
        &self.path
    }

    pub fn attachments(&self) -> Vec<Attachment> {
        self.log.lock().unwrap().attachments.clone()
    }

    pub fn attachment_count(&self) -> usize {
        self.log.lock().unwrap().attachments.len()
    }

    /// Drops every connection, leaving the socket accepting: what a client sees
    /// when the server it was attached to restarts.
    pub fn disconnect_all(&self) {
        for stream in &self.log.lock().unwrap().live {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }

    /// Waits for `condition` to hold, or gives up and returns false.
    ///
    /// Polled rather than signalled: what is being waited for is another
    /// process's threads noticing a socket, and there is nothing to signal on.
    pub fn wait_until(&self, timeout: Duration, condition: impl Fn(&[Attachment]) -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if condition(&self.attachments()) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

impl Drop for MockServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        // Nudges the accept loop out of `accept` so it sees the flag.
        let _ = UnixStream::connect(&self.path);
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Answers the handshake, then holds the connection open and reads until the
/// client's end goes away.
fn serve(mut stream: UnixStream, log: Arc<Mutex<Log>>) {
    let Ok(ClientMessage::EndpointControl { data, .. }) =
        read_message::<_, ClientMessage>(&mut stream, MAX_FRAME_SIZE)
    else {
        return;
    };
    let Ok(hello) = serde_json::from_str::<EndpointClientHello>(&data) else {
        return;
    };

    let index = {
        let mut log = log.lock().unwrap();
        log.attachments.push(Attachment {
            hello,
            closed: false,
            messages: Vec::new(),
        });
        if let Ok(handle) = stream.try_clone() {
            log.live.push(handle);
        }
        log.attachments.len() - 1
    };

    let welcome = EndpointServerWelcome {
        generation: ENDPOINT_PROTOCOL_GENERATION,
        server_version: herdr_protocol::VENDORED_HERDR_VERSION.to_owned(),
        snapshot_codec: SNAPSHOT_CODEC_V1.into(),
        surface_codec: SURFACE_CODEC_V1.into(),
        input_codec: INPUT_CODEC_V1.into(),
        blob_codec: BLOB_CODEC_V1.into(),
        methods: Vec::new(),
        capabilities: Vec::new(),
        error: None,
    };
    let reply = ServerMessage::EndpointControl {
        kind: ENDPOINT_WELCOME_KIND.into(),
        data: serde_json::to_string(&welcome).expect("encode welcome"),
    };
    if write_message(&mut stream, &reply).is_err() || stream.flush().is_err() {
        return;
    }

    // Reading is how the client's departure is noticed: this server has nothing
    // of its own to say, so an error or EOF here means the other end is gone.
    // What arrives on the way is kept, because a client tells a server things
    // the hello has no field for.
    while let Ok(message) = read_message::<_, ClientMessage>(&mut stream, MAX_FRAME_SIZE) {
        if let Ok(mut log) = log.lock() {
            log.attachments[index].messages.push(message);
        }
    }

    log.lock().unwrap().attachments[index].closed = true;
}
