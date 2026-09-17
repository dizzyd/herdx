//! Where a herdr server lives, and how to reach it.
//!
//! herdr clients are federated: the local server plus every saved SSH machine
//! appear together, so you can see an agent needing attention on another box
//! without switching to it. Each machine is a separate connection speaking the
//! same generation-1 protocol.

use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

/// A machine the client can attach to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// `local`, or the saved profile's opaque id.
    pub id: String,
    pub label: String,
    pub kind: EndpointKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EndpointKind {
    Local,
    Ssh { target: String, session: String },
}

/// A saved SSH machine, as herdr's client catalog stores it.
#[derive(serde::Deserialize)]
struct SavedSshEndpoint {
    id: String,
    label: String,
    target: String,
    session: String,
    #[serde(default)]
    enabled: bool,
}

#[derive(serde::Deserialize)]
struct Catalog {
    #[serde(default)]
    ssh: Vec<SavedSshEndpoint>,
}

#[derive(serde::Deserialize)]
struct Selection {
    #[serde(default)]
    selected_profile: Option<String>,
}

fn state_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_STATE_HOME") {
        return PathBuf::from(dir).join("herdr");
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join(".local")
        .join("state")
        .join("herdr")
}

fn client_state_dir() -> PathBuf {
    state_dir().join("client")
}

/// Every endpoint to attach to: the local server first, then enabled machines.
///
/// Disabled profiles are skipped rather than shown greyed out; herdr treats
/// disabling as "do not connect", and a row that can never come online is just
/// noise.
pub fn discover() -> Vec<Endpoint> {
    let mut endpoints = vec![Endpoint {
        id: "local".into(),
        label: "Local".into(),
        kind: EndpointKind::Local,
    }];

    let path = client_state_dir().join("endpoints.json");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return endpoints;
    };
    let Ok(catalog) = serde_json::from_str::<Catalog>(&text) else {
        return endpoints;
    };

    for profile in catalog.ssh.into_iter().filter(|profile| profile.enabled) {
        endpoints.push(Endpoint {
            id: profile.id,
            label: profile.label,
            kind: EndpointKind::Ssh {
                target: profile.target,
                session: profile.session,
            },
        });
    }
    endpoints
}

/// The endpoint herdr last had selected, so the app opens where you left off.
pub fn saved_selection() -> Option<String> {
    // `HERDX_ENDPOINT` picks an endpoint for one run without writing to the
    // selection the TUI shares, which matters for headless capture: a remote
    // endpoint needs an ssh key the agent may refuse, and there is no point
    // photographing a window that is still connecting.
    if let Ok(forced) = std::env::var("HERDX_ENDPOINT") {
        if !forced.is_empty() {
            return Some(forced);
        }
    }
    let text = std::fs::read_to_string(client_state_dir().join("endpoint-selection.json")).ok()?;
    serde_json::from_str::<Selection>(&text).ok()?.selected_profile
}

/// A duplex byte stream carrying the client protocol.
///
/// A local endpoint is a unix socket; a remote one is an ssh process running
/// `herdr remote-client-bridge`, which speaks the identical protocol on its
/// stdio. Treating them the same is what lets one connection implementation
/// serve both.
///
/// Transports are split rather than shared: the receive loop blocks on reads,
/// so writes need their own half. A socket can be cloned for that, but a
/// child's stdin cannot, so both are modelled as explicit halves.
pub struct Transport;

/// Keeps the ssh process alive while either half is in use, and reaps it once
/// both are gone.
struct ChildGuard(std::sync::Mutex<Child>);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Ok(mut child) = self.0.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub enum ReadHalf {
    Local(std::os::unix::net::UnixStream),
    Ssh {
        stdout: std::process::ChildStdout,
        /// What ssh wrote to stderr, for explaining a failure.
        ///
        /// Discarding it makes every problem — an unknown host key, a missing
        /// herdr on the far side, a refused connection — look identically like
        /// "the stream ended".
        diagnostics: std::sync::Arc<std::sync::Mutex<String>>,
        _child: std::sync::Arc<ChildGuard>,
    },
}

impl ReadHalf {
    /// Whatever the transport can say about why it failed.
    pub fn diagnostics(&self) -> Option<String> {
        match self {
            Self::Local(_) => None,
            Self::Ssh { diagnostics, .. } => {
                let text = diagnostics.lock().ok()?.trim().to_owned();
                (!text.is_empty()).then_some(text)
            }
        }
    }
}

pub enum WriteHalf {
    Local(std::os::unix::net::UnixStream),
    Ssh {
        stdin: std::process::ChildStdin,
        _child: std::sync::Arc<ChildGuard>,
    },
}

impl Transport {
    /// Opens a connection to an endpoint, split into read and write halves.
    pub fn connect(
        endpoint: &Endpoint,
        socket: &std::path::Path,
    ) -> io::Result<(ReadHalf, WriteHalf)> {
        match &endpoint.kind {
            EndpointKind::Local => {
                let stream = std::os::unix::net::UnixStream::connect(socket)?;
                let writer = stream.try_clone()?;
                Ok((ReadHalf::Local(stream), WriteHalf::Local(writer)))
            }
            EndpointKind::Ssh { target, session } => start_ssh(target, session),
        }
    }
}

/// Spawns `herdr remote-client-bridge` over ssh.
fn start_ssh(target: &str, session: &str) -> io::Result<(ReadHalf, WriteHalf)> {
    let mut command = Command::new("ssh");
    command
        // Fail rather than hang waiting for a password or a host-key prompt:
        // there is no terminal here to answer one, so a stall would look like
        // a machine that is merely slow.
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ConnectTimeout=10")
        .arg("-o")
        .arg("ServerAliveInterval=30")
        .arg(target)
        .arg("herdr");
    if session != "default" {
        command.arg("--session").arg(session);
    }
    command
        .arg("remote-client-bridge")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn()?;
    let stdin = child.stdin.take().expect("piped stdin");
    let stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let guard = std::sync::Arc::new(ChildGuard(std::sync::Mutex::new(child)));

    let diagnostics = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let sink = std::sync::Arc::clone(&diagnostics);
    std::thread::spawn(move || {
        let mut text = String::new();
        // Bounded: a chatty remote must not grow this without limit.
        let mut buffer = [0u8; 1024];
        while let Ok(read) = stderr.read(&mut buffer) {
            if read == 0 {
                break;
            }
            text.push_str(&String::from_utf8_lossy(&buffer[..read]));
            if text.len() > 4096 {
                text = text.split_off(text.len() - 4096);
            }
            if let Ok(mut sink) = sink.lock() {
                sink.clone_from(&text);
            }
        }
    });

    Ok((
        ReadHalf::Ssh {
            stdout,
            diagnostics,
            _child: std::sync::Arc::clone(&guard),
        },
        WriteHalf::Ssh {
            stdin,
            _child: guard,
        },
    ))
}

impl Read for ReadHalf {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Local(stream) => stream.read(buf),
            Self::Ssh { stdout, .. } => stdout.read(buf),
        }
    }
}

impl Write for WriteHalf {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Self::Local(stream) => stream.write(buf),
            Self::Ssh { stdin, .. } => stdin.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Local(stream) => stream.flush(),
            Self::Ssh { stdin, .. } => stdin.flush(),
        }
    }
}
