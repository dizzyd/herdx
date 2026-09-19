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
    pub fn start(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "herdx-mock-{name}-{}-{:?}.sock",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);
        let listener = Arc::new(UnixListener::bind(&path).expect("bind mock socket"));

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
    while read_message::<_, ClientMessage>(&mut stream, MAX_FRAME_SIZE).is_ok() {}

    log.lock().unwrap().attachments[index].closed = true;
}
