//! Where a herdr server lives, and how to reach it.
//!
//! herdr clients are federated: the local server plus every saved SSH machine
//! appear together, so you can see an agent needing attention on another box
//! without switching to it. Each machine is a separate connection speaking the
//! same generation-1 protocol.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
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
#[derive(Debug, serde::Deserialize, serde::Serialize)]
struct SavedSshEndpoint {
    id: String,
    label: String,
    target: String,
    session: String,
    #[serde(default)]
    enabled: bool,
}

#[derive(Debug, serde::Deserialize)]
struct Catalog {
    #[serde(default)]
    ssh: Vec<SavedSshEndpoint>,
    /// Carried through a rewrite untouched: it is herdr's to set, but dropping
    /// it would forget which machine the TUI opens on.
    #[serde(default)]
    selected_profile: Option<String>,
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

/// The local server on its own.
///
/// A window does not have to carry the machines: a session made to be new has
/// nothing to do with whatever another machine is running, and herdr's catalog
/// is about which machines exist, not which ones every window must show.
pub fn local() -> Endpoint {
    Endpoint {
        id: "local".into(),
        label: "Local".into(),
        kind: EndpointKind::Local,
    }
}

/// Every endpoint to attach to: the local server first, then enabled machines.
///
/// Disabled profiles are skipped rather than shown greyed out; herdr treats
/// disabling as "do not connect", and a row that can never come online is just
/// noise.
pub fn discover() -> Vec<Endpoint> {
    let mut endpoints = vec![local()];

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

/// Every saved machine, enabled or not.
#[derive(Debug, serde::Serialize)]
pub struct Machine {
    pub id: String,
    pub label: String,
    pub target: String,
    pub session: String,
    pub enabled: bool,
}

pub fn machines() -> Result<Vec<Machine>, String> {
    machines_in(&client_state_dir())
}

fn machines_in(directory: &Path) -> Result<Vec<Machine>, String> {
    Ok(load_catalog_in(directory)?
        .ssh
        .into_iter()
        .map(|entry| Machine {
            id: entry.id,
            label: entry.label,
            target: entry.target,
            session: entry.session,
            enabled: entry.enabled,
        })
        .collect())
}

/// Adds or replaces an SSH machine in the catalog herdr shares.
///
/// The catalog is herdr's file, not ours, and it is read with
/// `deny_unknown_fields`: an entry carrying anything beyond these five keys
/// makes herdr reject the whole file. So this writes exactly that shape, and
/// applies herdr's own limits rather than inventing its own.
pub fn save_machine(
    id: Option<&str>,
    label: &str,
    target: &str,
    session: &str,
    enabled: bool,
) -> Result<String, String> {
    save_machine_in(&client_state_dir(), id, label, target, session, enabled)
}

fn save_machine_in(
    directory: &Path,
    id: Option<&str>,
    label: &str,
    target: &str,
    session: &str,
    enabled: bool,
) -> Result<String, String> {
    let label = label.trim();
    let target = target.trim();
    let session = if session.trim().is_empty() {
        "default"
    } else {
        session.trim()
    };

    if label.is_empty() {
        return Err("Name cannot be empty".into());
    }
    if target.is_empty() {
        return Err("SSH target cannot be empty".into());
    }
    if label.len() > 128 || label.chars().any(char::is_control) {
        return Err("Name is too long".into());
    }
    if target.len() > 1024 || target.chars().any(char::is_control) {
        return Err("SSH target is too long".into());
    }
    // herdr reads this target back as a command-line argument, so one starting
    // with a dash would be taken for a flag.
    if target.starts_with('-') {
        return Err("SSH target must not start with '-'".into());
    }
    // herdr refuses a target carrying a password, and so should the thing
    // writing its file.
    let authority = target.strip_prefix("ssh://").unwrap_or(target);
    if authority
        .rsplit_once('@')
        .is_some_and(|(userinfo, _)| userinfo.contains(':'))
    {
        return Err("SSH target must not contain a password".into());
    }
    validate_session_name(session)?;

    let mut catalog = load_catalog_in(directory)?;
    let id = match id {
        Some(existing) => existing.to_owned(),
        None => new_profile_id(),
    };

    let entry = SavedSshEndpoint {
        id: id.clone(),
        label: label.to_owned(),
        target: target.to_owned(),
        session: session.to_owned(),
        enabled,
    };

    match catalog.ssh.iter_mut().find(|e| e.id == id) {
        Some(slot) => *slot = entry,
        None => {
            if catalog.ssh.len() >= 64 {
                return Err("herdr allows at most 64 machines".into());
            }
            catalog.ssh.push(entry);
        }
    }
    // A selection herdr cannot honour is worse than no selection: it validates
    // the whole catalog on load and refuses one that points at a disabled
    // machine, so this would cost the user every machine rather than one.
    // `Catalog::set_enabled` upstream does the same.
    if !enabled && catalog.selected_profile.as_deref() == Some(id.as_str()) {
        catalog.selected_profile = None;
    }
    write_catalog_in(directory, &catalog)?;
    Ok(id)
}

/// herdr's rules for a session name, from `session::validate_name`.
///
/// These belong here rather than at the window: herdr validates every entry
/// when it loads the catalog, and rejects the whole file if one fails. A typo
/// in a session name is therefore not one broken machine — it is every machine
/// the user has, gone from herdr until the file is edited by hand.
fn validate_session_name(name: &str) -> Result<(), String> {
    const MAX_SESSION_NAME_LEN: usize = 64;

    if name.is_empty() {
        return Err("Session name cannot be empty".into());
    }
    if name.len() > MAX_SESSION_NAME_LEN {
        return Err(format!(
            "Session name cannot be longer than {MAX_SESSION_NAME_LEN} bytes"
        ));
    }
    if name == "." || name == ".." {
        return Err("Session name cannot be . or ..".into());
    }
    if !name
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(
            "Session name may only contain ASCII letters, numbers, '.', '_' and '-'".into(),
        );
    }
    Ok(())
}

/// Removes a machine. Missing is not an error: the catalog is shared, and
/// something else may have removed it already.
pub fn remove_machine(id: &str) -> Result<(), String> {
    remove_machine_in(&client_state_dir(), id)
}

fn remove_machine_in(directory: &Path, id: &str) -> Result<(), String> {
    let mut catalog = load_catalog_in(directory)?;
    catalog.ssh.retain(|entry| entry.id != id);
    // Same rule as disabling one, and the same cost for getting it wrong.
    // `Catalog::remove_ssh` upstream does the same.
    if catalog.selected_profile.as_deref() == Some(id) {
        catalog.selected_profile = None;
    }
    write_catalog_in(directory, &catalog)
}

/// Reads the catalog, distinguishing "there isn't one yet" from "it could not
/// be read".
///
/// Only a missing file is an empty catalog. Treating an unreadable or malformed
/// one as empty too is what made a save destroy it: every caller here writes
/// the catalog back, so a parse error silently became "delete every machine the
/// user had". A failure has to reach the person instead, with the file still on
/// disk to recover from.
fn load_catalog_in(directory: &Path) -> Result<Catalog, String> {
    let path = directory.join("endpoints.json");
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(Catalog {
                ssh: Vec::new(),
                selected_profile: None,
            })
        }
        Err(error) => return Err(format!("cannot read {}: {error}", path.display())),
    };
    serde_json::from_str::<Catalog>(&text)
        .map_err(|error| format!("{} is not a catalog herdr wrote: {error}", path.display()))
}

/// Writes through a temporary file, as herdr does: a catalog half-written
/// because something died mid-save is one herdr will refuse to load at all.
fn write_catalog_in(directory: &Path, catalog: &Catalog) -> Result<(), String> {
    #[derive(serde::Serialize)]
    struct Out<'a> {
        version: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        selected_profile: &'a Option<String>,
        ssh: &'a [SavedSshEndpoint],
    }

    std::fs::create_dir_all(directory).map_err(|e| format!("cannot create state dir: {e}"))?;

    let text = serde_json::to_string_pretty(&Out {
        version: 1,
        selected_profile: &catalog.selected_profile,
        ssh: &catalog.ssh,
    })
    .map_err(|e| format!("cannot encode catalog: {e}"))?;

    let path = directory.join("endpoints.json");
    let temp = directory.join(format!("endpoints.json.hx{}", std::process::id()));
    std::fs::write(&temp, text).map_err(|e| format!("cannot write catalog: {e}"))?;
    std::fs::rename(&temp, &path).map_err(|e| {
        let _ = std::fs::remove_file(&temp);
        format!("cannot replace catalog: {e}")
    })
}

/// herdr's profile ids are 32 lowercase hex characters.
fn new_profile_id() -> String {
    let mut bytes = [0u8; 16];
    getrandom(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn getrandom(buffer: &mut [u8]) {
    use std::time::{SystemTime, UNIX_EPOCH};
    // Uniqueness is all that is needed here: the id names a row in a file the
    // user owns, and herdr only requires that it parse as 32 hex characters.
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
        ^ (std::process::id() as u64) << 32;
    for slot in buffer.iter_mut() {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *slot = (seed >> 33) as u8;
    }
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
pub(crate) struct Transport;

/// Keeps the ssh process alive while either half is in use, and reaps it once
/// both are gone.
pub(crate) struct ChildGuard(std::sync::Mutex<Child>);

impl ChildGuard {
    /// Kills the ssh process now, without waiting for the last half to drop.
    ///
    /// Both halves hold a reference, and one of them is parked inside a
    /// blocking read on the child's own stdout — so waiting for the refcount to
    /// fall to zero waits for the thing the kill is meant to interrupt.
    fn kill(&self) {
        if let Ok(mut child) = self.0.lock() {
            let _ = child.kill();
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Ok(mut child) = self.0.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Breaks a blocked read on a connection, from another thread.
///
/// A receive loop spends nearly all of its life parked in `read`, and nothing
/// short of the far end speaking will return from it. Disposing of a session
/// has to be able to, or freeing one leaves its thread, its socket and its ssh
/// process running until the machine happens to say something.
pub(crate) enum Interrupt {
    Local(std::os::unix::net::UnixStream),
    Ssh(std::sync::Arc<ChildGuard>),
}

impl Interrupt {
    pub fn wake(&self) {
        match self {
            // Shuts the socket down for every clone of it, which is what makes
            // the reader's blocked `read` return rather than this one's.
            Self::Local(stream) => {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            Self::Ssh(child) => child.kill(),
        }
    }
}

pub(crate) enum ReadHalf {
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

pub(crate) enum WriteHalf {
    Local(std::os::unix::net::UnixStream),
    Ssh {
        stdin: std::process::ChildStdin,
        _child: std::sync::Arc<ChildGuard>,
    },
}

impl Transport {
    /// Opens a connection to an endpoint, split into read and write halves.
    ///
    /// `cancelled` is asked while anything slow happens before there is a
    /// transport to interrupt.
    pub fn connect(
        endpoint: &Endpoint,
        socket: &std::path::Path,
        cancelled: &dyn Fn() -> bool,
    ) -> io::Result<(ReadHalf, WriteHalf, Interrupt)> {
        match &endpoint.kind {
            EndpointKind::Local => {
                let stream = std::os::unix::net::UnixStream::connect(socket)?;
                let writer = stream.try_clone()?;
                let interrupt = Interrupt::Local(stream.try_clone()?);
                Ok((ReadHalf::Local(stream), WriteHalf::Local(writer), interrupt))
            }
            EndpointKind::Ssh { target, session } => start_ssh(target, session, cancelled),
        }
    }
}

/// Spawns `herdr remote-client-bridge` over ssh.
/// The command to run on the far side.
///
/// `ssh host herdr …` runs a non-interactive, non-login shell, and
/// `~/.local/bin` — where herdr installs itself — is usually not on the PATH
/// such a shell gets. herdr's own remote attach uses the absolute path for
/// exactly this reason, so a machine with herdr installed would otherwise look
/// to us like a machine without it.
fn remote_bridge_command(session: &str) -> String {
    let arguments = if session == "default" {
        "remote-client-bridge".to_owned()
    } else {
        format!("--session {} remote-client-bridge", shell_quoted(session))
    };
    format!(
        "if [ -x \"$HOME/.local/bin/herdr\" ]; then exec \"$HOME/.local/bin/herdr\" {arguments}; \
         else exec herdr {arguments}; fi"
    )
}

/// Single-quoted for the remote shell. herdr validates session names, but the
/// catalog is a file a person edits.
fn shell_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// The ssh agent the user's own shell would hand to `ssh`.
///
/// An app opened from the Finder inherits launchd's `SSH_AUTH_SOCK`, and a
/// shell profile can point that somewhere else — 1Password, Secretive,
/// gpg-agent. When it does, keys available through the configured agent are
/// not available to us, and a machine that accepts the same `ssh` from a
/// terminal answers "Permission denied (publickey)".
static SSH_AGENT: AgentCache = AgentCache::new(
    ask_login_shell_for_ssh_agent,
    std::time::Duration::from_secs(5 * 60),
    std::time::Duration::from_secs(60),
);

/// One login shell's answer, shared by every machine.
///
/// A login shell is slow, so an answer is kept — but only while its socket
/// still exists, since an agent that restarts elsewhere leaves the old path
/// pointing at nothing, and refreshed in the background after a while for an
/// agent that moved without the old one going away. A failure is retried
/// rather than believed forever, but not on every reconnect.
///
/// The asking runs on its own thread. A connection waiting for it can be
/// abandoned, which matters because disposal joins the connection's thread on
/// the main thread.
struct AgentCache {
    lookup: fn() -> Option<std::ffi::OsString>,
    refresh_after: std::time::Duration,
    retry_after: std::time::Duration,
    state: std::sync::Mutex<AgentState>,
    answered: std::sync::Condvar,
}

struct AgentState {
    found: Option<(std::ffi::OsString, std::time::Instant)>,
    failed_at: Option<std::time::Instant>,
    asking: bool,
}

impl AgentCache {
    const fn new(
        lookup: fn() -> Option<std::ffi::OsString>,
        refresh_after: std::time::Duration,
        retry_after: std::time::Duration,
    ) -> Self {
        Self {
            lookup,
            refresh_after,
            retry_after,
            state: std::sync::Mutex::new(AgentState {
                found: None,
                failed_at: None,
                asking: false,
            }),
            answered: std::sync::Condvar::new(),
        }
    }

    /// The agent to use, or None to leave `ssh` the environment we inherited.
    fn get(&'static self, cancelled: &dyn Fn() -> bool) -> Option<std::ffi::OsString> {
        let mut state = self.state.lock().unwrap();
        loop {
            let retry_due = state
                .failed_at
                .is_none_or(|at| at.elapsed() >= self.retry_after);
            if let Some((agent, at)) = &state.found {
                // Checked again here as well as when it was stored: an agent
                // that restarts elsewhere leaves the old path pointing at
                // nothing, and that is worth noticing between refreshes.
                if Path::new(agent).exists() {
                    let agent = agent.clone();
                    if at.elapsed() >= self.refresh_after && retry_due && !state.asking {
                        self.ask(&mut state);
                    }
                    return Some(agent);
                }
                state.found = None;
            }
            if !state.asking {
                if !retry_due {
                    return None;
                }
                self.ask(&mut state);
            }
            // Polled rather than woken: what cancels a connection is its own
            // halt, which knows nothing of this condvar.
            if cancelled() {
                return None;
            }
            state = self
                .answered
                .wait_timeout(state, std::time::Duration::from_millis(50))
                .unwrap()
                .0;
        }
    }

    fn ask(&'static self, state: &mut AgentState) {
        state.asking = true;
        let spawned = std::thread::Builder::new()
            .name("herdx-ssh-agent".into())
            .spawn(move || {
                let found = (self.lookup)();
                let mut state = self.state.lock().unwrap();
                state.asking = false;
                match found {
                    // A path that is not there is not an answer, however
                    // confidently the shell printed it. Taken as a success it
                    // cleared the cooldown, and `get` then threw it away for
                    // not existing and asked again in the same breath — a
                    // login shell per turn of the loop, forever, with
                    // `start_ssh` never reached at all. A machine whose key
                    // needs no agent could not connect while a stale
                    // `SSH_AUTH_SOCK` sat in somebody's profile.
                    Some(agent) if std::path::Path::new(&agent).exists() => {
                        state.found = Some((agent, std::time::Instant::now()));
                        state.failed_at = None;
                    }
                    _ => {
                        state.found = None;
                        state.failed_at = Some(std::time::Instant::now());
                    }
                }
                self.answered.notify_all();
            });
        if spawned.is_err() {
            state.asking = false;
            state.failed_at = Some(std::time::Instant::now());
        }
    }
}

const AGENT_MARK: &[u8] = b"__herdx_ssh_auth_sock__";

fn ask_login_shell_for_ssh_agent() -> Option<std::ffi::OsString> {
    let shell = std::env::var_os("SHELL")
        .filter(|shell| !shell.is_empty())
        .unwrap_or_else(|| "/bin/zsh".into());
    let mark = std::str::from_utf8(AGENT_MARK).expect("ascii");
    let mut command = Command::new(shell);
    // Interactive as well as login: plenty of people set this in `.zshrc`.
    // The markers step over whatever the profile prints on the way.
    command
        .arg("-l")
        .arg("-i")
        .arg("-c")
        .arg(format!("printf '{mark}%s{mark}' \"$SSH_AUTH_SOCK\""));
    framed_output(command, std::time::Duration::from_secs(5))
}

/// Runs `command` and returns what it printed between two `AGENT_MARK`s,
/// giving up at `timeout`.
///
/// Read here, against the deadline, rather than on a thread of its own:
/// something a profile starts in the background can inherit stdout and hold
/// it open long after the shell has gone, and a blocked read cannot be
/// abandoned — only its pipe can be closed, which returning does.
///
/// The shell runs in a process group of its own. On a timeout the whole group
/// is killed, since a stalled profile is usually stalled in a child. On an
/// answer only the shell is: anything the profile started and left running —
/// an agent, often — is the user's, not ours to stop.
fn framed_output(mut command: Command, timeout: std::time::Duration) -> Option<std::ffi::OsString> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::process::CommandExt;

    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let output = read_framed(stdout, std::time::Instant::now() + timeout);
    if output.is_none() {
        // Not yet reaped, so the id cannot have been reused.
        unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
    }
    let _ = child.kill();
    let _ = child.wait();
    output
        .filter(|agent| !agent.is_empty())
        .map(|agent| std::ffi::OsStr::from_bytes(&agent).to_owned())
}

/// Bytes accumulated and decoded once, at the end: a chunk boundary can fall
/// inside a character, and a socket path need not be UTF-8 at all.
fn read_framed(
    mut pipe: impl Read + std::os::fd::AsRawFd,
    deadline: std::time::Instant,
) -> Option<Vec<u8>> {
    // Far more than any profile's greeting; a pipe that keeps talking past it
    // is not going to say anything useful.
    const LIMIT: usize = 64 * 1024;
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        if let Some(value) = framed(&bytes) {
            return Some(value.to_vec());
        }
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() || bytes.len() > LIMIT {
            return None;
        }
        let mut poll = libc::pollfd {
            fd: pipe.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let wait = remaining.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
        if unsafe { libc::poll(&mut poll, 1, wait) } < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return None;
        }
        if poll.revents == 0 {
            continue;
        }
        match pipe.read(&mut buffer) {
            Ok(0) => return None,
            Ok(read) => bytes.extend_from_slice(&buffer[..read]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
}

/// What sits between the first two `AGENT_MARK`s.
fn framed(bytes: &[u8]) -> Option<&[u8]> {
    let find = |haystack: &[u8]| {
        haystack
            .windows(AGENT_MARK.len())
            .position(|window| window == AGENT_MARK)
    };
    let start = find(bytes)? + AGENT_MARK.len();
    let length = find(&bytes[start..])?;
    Some(&bytes[start..start + length])
}

/// How much of a remote's stderr to keep.
const DIAGNOSTICS_LIMIT: usize = 4096;

/// Appends to a tail that never grows past `limit`, in bytes.
///
/// Bytes rather than characters because trimming a `String` to its last
/// `limit` bytes panics when the cut lands inside one — `split_off` asserts a
/// char boundary, and a euro sign followed by 4094 of anything puts the cut in
/// the middle of it. The panic ended the thread that reads a machine's stderr
/// and dropped the pipe with it, so a machine that then failed to connect
/// explained itself with "the stream ended" and nothing else: the one case the
/// diagnostics exist for.
fn append_bounded(tail: &mut Vec<u8>, bytes: &[u8], limit: usize) {
    tail.extend_from_slice(bytes);
    if tail.len() > limit {
        tail.drain(..tail.len() - limit);
    }
}

fn start_ssh(
    target: &str,
    session: &str,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<(ReadHalf, WriteHalf, Interrupt)> {
    let agent = SSH_AGENT.get(cancelled);
    if cancelled() {
        return Err(io::Error::other("endpoint was closed while connecting"));
    }
    let mut command = Command::new("ssh");
    command
        // Fail rather than hang waiting for a password or a host-key prompt:
        // there is no terminal here to answer one, so a stall would look like
        // a machine that is merely slow.
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ConnectTimeout=10")
        // How long a connection whose path died unnoticed stays believed.
        // ssh gives up after `(ServerAliveCountMax + 1) * ServerAliveInterval`
        // — measured at 120s with the 30s interval this used to carry, and 40s
        // with these. A wake from sleep does not wait for either, since
        // `hx_reattach_remotes` is told about it; this is for the drops nothing
        // announces, which is a Wi-Fi roam, a VPN flap or a machine rebooting.
        // Three missed probes ten seconds apart is a link that is really gone,
        // and reattaching costs a handshake and a surface resend, not a pane.
        .arg("-o")
        .arg("ServerAliveInterval=10")
        .arg("-o")
        .arg("ServerAliveCountMax=3")
        .arg(target)
        .arg(remote_bridge_command(session));
    if let Some(agent) = agent {
        command.env("SSH_AUTH_SOCK", agent);
    }
    command
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
        // Bytes, decoded only when published. Two reasons, both of which bit:
        // trimming a `String` to its last 4096 *bytes* panics when the cut
        // lands inside a character — three bytes of euro sign followed by 4094
        // of anything is enough — and that panic ends this thread and drops the
        // pipe, so the machine then fails with no diagnostics at all, which is
        // the thing this exists to prevent. Decoding each read on its own also
        // mangled any character that straddled two of them.
        let mut tail: Vec<u8> = Vec::new();
        let mut buffer = [0u8; 1024];
        while let Ok(read) = stderr.read(&mut buffer) {
            if read == 0 {
                break;
            }
            append_bounded(&mut tail, &buffer[..read], DIAGNOSTICS_LIMIT);
            if let Ok(mut sink) = sink.lock() {
                *sink = String::from_utf8_lossy(&tail).into_owned();
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
            _child: std::sync::Arc::clone(&guard),
        },
        Interrupt::Ssh(guard),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory of its own per test, removed when the test ends.
    ///
    /// The catalog helpers take the directory rather than reading
    /// `XDG_STATE_HOME`, so these tests never touch the developer's real
    /// catalog and can run in parallel with each other.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "herdx-endpoint-{name}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("temp dir");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }

        fn catalog(&self) -> PathBuf {
            self.0.join("endpoints.json")
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn missing_catalog_reads_as_empty() {
        let dir = TempDir::new("missing");
        let catalog = load_catalog_in(dir.path()).expect("a missing catalog is simply empty");
        assert!(catalog.ssh.is_empty());
        assert_eq!(catalog.selected_profile, None);
    }

    #[test]
    fn malformed_catalog_is_an_error_not_an_empty_one() {
        let dir = TempDir::new("malformed");
        std::fs::write(dir.catalog(), "{ this is not json").unwrap();

        let error = load_catalog_in(dir.path()).expect_err("malformed JSON must not read as empty");
        assert!(error.contains("endpoints.json"), "{error}");
    }

    #[test]
    fn saving_over_a_malformed_catalog_leaves_the_file_alone() {
        let dir = TempDir::new("save-malformed");
        let original = "{ \"ssh\": [ truncated";
        std::fs::write(dir.catalog(), original).unwrap();

        let error = save_machine_in(dir.path(), None, "Box", "user@host", "default", true)
            .expect_err("a save must not proceed over a catalog it could not read");
        assert!(error.contains("endpoints.json"), "{error}");
        assert_eq!(
            std::fs::read_to_string(dir.catalog()).unwrap(),
            original,
            "the unreadable catalog is what the user has to recover from"
        );
    }

    #[test]
    fn removing_over_a_malformed_catalog_leaves_the_file_alone() {
        let dir = TempDir::new("remove-malformed");
        let original = "not json at all";
        std::fs::write(dir.catalog(), original).unwrap();

        save_machine_in(dir.path(), Some("abc"), "Box", "user@host", "default", true).unwrap_err();
        let error = remove_machine_in(dir.path(), "abc")
            .expect_err("a remove must not proceed over a catalog it could not read");
        assert!(error.contains("endpoints.json"), "{error}");
        assert_eq!(std::fs::read_to_string(dir.catalog()).unwrap(), original);
    }

    #[test]
    fn listing_an_unreadable_catalog_reports_the_failure() {
        let dir = TempDir::new("list-malformed");
        std::fs::write(dir.catalog(), r#"{ "ssh": "not a list" }"#).unwrap();

        machines_in(dir.path()).expect_err("a catalog that will not parse is not no machines");
    }

    #[test]
    fn saving_preserves_existing_entries_and_herdrs_selection() {
        let dir = TempDir::new("preserve");
        std::fs::write(
            dir.catalog(),
            r#"{
              "version": 1,
              "selected_profile": "00112233445566778899aabbccddeeff",
              "ssh": [
                {
                  "id": "00112233445566778899aabbccddeeff",
                  "label": "First",
                  "target": "user@first",
                  "session": "default",
                  "enabled": true
                }
              ]
            }"#,
        )
        .unwrap();

        save_machine_in(dir.path(), None, "Second", "user@second", "work", true).unwrap();

        let saved = machines_in(dir.path()).unwrap();
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[0].label, "First");
        assert_eq!(saved[1].label, "Second");
        assert_eq!(saved[1].session, "work");

        let written = load_catalog_in(dir.path()).unwrap();
        assert_eq!(
            written.selected_profile.as_deref(),
            Some("00112233445566778899aabbccddeeff"),
            "herdr's selection is its own and must survive our rewrite"
        );
    }

    /// One enabled machine, selected.
    fn selected_catalog(dir: &TempDir, enabled: bool) {
        std::fs::write(
            dir.catalog(),
            format!(
                r#"{{
              "version": 1,
              "selected_profile": "00112233445566778899aabbccddeeff",
              "ssh": [
                {{
                  "id": "00112233445566778899aabbccddeeff",
                  "label": "Only",
                  "target": "user@only",
                  "session": "default",
                  "enabled": {enabled}
                }}
              ]
            }}"#
            ),
        )
        .unwrap();
    }

    /// herdr rejects the whole catalog when the selection is absent, so this
    /// is not one machine gone — it is every machine the user has.
    #[test]
    fn removing_the_selected_machine_clears_the_selection() {
        let dir = TempDir::new("remove-selected");
        selected_catalog(&dir, true);

        remove_machine_in(dir.path(), "00112233445566778899aabbccddeeff").unwrap();

        let written = load_catalog_in(dir.path()).unwrap();
        assert!(written.ssh.is_empty());
        assert_eq!(
            written.selected_profile, None,
            "the catalog still selects a machine that is not in it"
        );
    }

    /// Same rule: herdr rejects a selection that is present but disabled.
    #[test]
    fn disabling_the_selected_machine_clears_the_selection() {
        let dir = TempDir::new("disable-selected");
        selected_catalog(&dir, true);

        save_machine_in(
            dir.path(),
            Some("00112233445566778899aabbccddeeff"),
            "Only",
            "user@only",
            "default",
            false,
        )
        .unwrap();

        let written = load_catalog_in(dir.path()).unwrap();
        assert_eq!(written.ssh.len(), 1);
        assert!(!written.ssh[0].enabled);
        assert_eq!(
            written.selected_profile, None,
            "the catalog still selects a disabled machine"
        );
    }

    /// Disabling one machine says nothing about a different selection.
    #[test]
    fn disabling_another_machine_leaves_the_selection_alone() {
        let dir = TempDir::new("disable-other");
        selected_catalog(&dir, true);
        let other = save_machine_in(dir.path(), None, "Other", "user@other", "default", true)
            .unwrap();

        save_machine_in(dir.path(), Some(&other), "Other", "user@other", "default", false).unwrap();

        let written = load_catalog_in(dir.path()).unwrap();
        assert_eq!(
            written.selected_profile.as_deref(),
            Some("00112233445566778899aabbccddeeff"),
            "herdr's selection is its own and must survive our rewrite"
        );
    }

    #[test]
    fn a_session_name_herdr_would_refuse_is_refused_here() {
        let dir = TempDir::new("session-names");

        for bad in ["bad/session", "with space", "..", ".", "tab\there", &"x".repeat(65)] {
            let error = save_machine_in(dir.path(), None, "Box", "user@host", bad, true)
                .expect_err(&format!("{bad:?} is a name herdr refuses"));
            assert!(
                error.to_lowercase().contains("session name"),
                "{bad:?} was refused for the wrong reason: {error}"
            );
        }

        for good in ["default", "hxtest", "work-1", "a.b_c", &"x".repeat(64)] {
            save_machine_in(dir.path(), Some("id-for-good"), "Box", "user@host", good, true)
                .unwrap_or_else(|error| panic!("{good:?} is a name herdr accepts: {error}"));
        }
    }

    #[test]
    fn a_target_starting_with_a_dash_is_refused() {
        let dir = TempDir::new("dash-target");

        let error = save_machine_in(dir.path(), None, "Box", "-V", "default", true)
            .expect_err("herdr reads the target back as an argument");
        assert!(error.contains("must not start with '-'"), "{error}");

        assert!(
            machines_in(dir.path()).unwrap().is_empty(),
            "a refused machine must not reach the catalog"
        );
    }

    #[test]
    fn an_empty_session_still_becomes_default() {
        let dir = TempDir::new("empty-session");

        // The empty string fails herdr's rules, but it never reaches them:
        // blank means "the default session", which is what gets validated.
        let id = save_machine_in(dir.path(), None, "Box", "user@host", "   ", true).unwrap();
        assert_eq!(machines_in(dir.path()).unwrap()[0].session, "default");
        assert_eq!(machines_in(dir.path()).unwrap()[0].id, id);
    }

    #[test]
    fn a_target_carrying_a_password_is_still_refused() {
        let dir = TempDir::new("password");

        save_machine_in(dir.path(), None, "Box", "ssh://user:secret@host", "default", true)
            .expect_err("herdr refuses a target carrying a password");
    }

    #[test]
    fn a_saved_machine_round_trips_through_the_catalog() {
        let dir = TempDir::new("round-trip");

        let id = save_machine_in(dir.path(), None, "Box", "user@host", "", true).unwrap();
        assert_eq!(id.len(), 32);

        let saved = machines_in(dir.path()).unwrap();
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].id, id);
        assert_eq!(saved[0].session, "default", "an empty session means default");

        remove_machine_in(dir.path(), &id).unwrap();
        assert!(machines_in(dir.path()).unwrap().is_empty());
    }

    fn sh(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        command
    }

    fn alive(pid: &str) -> bool {
        let pid: libc::pid_t = pid.trim().parse().expect("pid");
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[test]
    fn an_agent_is_read_from_between_the_markers() {
        let noisy = sh("printf 'welcome\\n__herdx_ssh_auth_sock__/tmp/agent.sock__herdx_ssh_auth_sock__bye'");
        assert_eq!(
            framed_output(noisy, std::time::Duration::from_secs(5)),
            Some("/tmp/agent.sock".into())
        );
        let unset = sh("printf '__herdx_ssh_auth_sock____herdx_ssh_auth_sock__'");
        assert_eq!(framed_output(unset, std::time::Duration::from_secs(5)), None);
        let unframed = sh("printf '__herdx_ssh_auth_sock__/tmp/agent.sock'");
        assert_eq!(framed_output(unframed, std::time::Duration::from_secs(5)), None);
    }

    #[test]
    fn a_character_split_across_reads_survives() {
        // The two bytes of é, written separately so they arrive in two reads.
        let split = sh(
            "printf '__herdx_ssh_auth_sock__/tmp/agent-\\303'; sleep 0.2; \
             printf '\\251.sock__herdx_ssh_auth_sock__'",
        );
        assert_eq!(
            framed_output(split, std::time::Duration::from_secs(5)),
            Some("/tmp/agent-é.sock".into())
        );
    }

    /// The input that used to end the thread that reads a machine's stderr.
    ///
    /// Three bytes of euro sign then 4094 ASCII is 4097 bytes, so trimming to
    /// the last 4096 cut one byte in — inside the euro sign. `split_off`
    /// asserts a char boundary, so it panicked, the diagnostics thread died
    /// and the pipe went with it; the machine then failed to connect with no
    /// explanation, which is the one thing the diagnostics are for.
    #[test]
    fn a_diagnostics_tail_cut_inside_a_character_does_not_panic() {
        let mut tail = Vec::new();
        let mut text = String::from("\u{20AC}");
        text.push_str(&"a".repeat(4094));
        assert_eq!(text.len(), 4097, "the input no longer straddles the cut");

        append_bounded(&mut tail, text.as_bytes(), DIAGNOSTICS_LIMIT);

        assert_eq!(tail.len(), DIAGNOSTICS_LIMIT);
        // The severed byte is published as a replacement glyph, which is what
        // a diagnostic should do with a fragment rather than refuse to exist.
        let shown = String::from_utf8_lossy(&tail);
        assert!(shown.ends_with("aaa"), "the tail lost its end");
        assert!(shown.starts_with('\u{fffd}'), "a half character read as whole");
    }

    /// Decoding each read on its own mangled anything that straddled two of
    /// them, which keeping bytes until publication also fixes.
    #[test]
    fn a_diagnostics_character_split_across_reads_survives() {
        let mut tail = Vec::new();
        let euro = "\u{20AC}".as_bytes();

        append_bounded(&mut tail, &euro[..1], DIAGNOSTICS_LIMIT);
        append_bounded(&mut tail, &euro[1..], DIAGNOSTICS_LIMIT);

        assert_eq!(String::from_utf8_lossy(&tail), "\u{20AC}");
    }

    #[test]
    fn a_diagnostics_tail_under_the_limit_is_kept_whole() {
        let mut tail = Vec::new();
        append_bounded(&mut tail, b"ssh: connect refused", DIAGNOSTICS_LIMIT);
        assert_eq!(String::from_utf8_lossy(&tail), "ssh: connect refused");
    }

    #[test]
    fn a_stalled_profile_is_abandoned_with_its_children() {
        let dir = TempDir::new("agent-stall");
        let pidfile = dir.path().join("pid");
        // The descendant inherits stdout, so the pipe stays open after the
        // shell is killed; this is what used to leave a reader blocked.
        let stalled = sh(&format!(
            "sleep 30 & echo $! > '{}'; printf 'starting'; sleep 30",
            pidfile.display()
        ));
        let started = std::time::Instant::now();
        assert_eq!(framed_output(stalled, std::time::Duration::from_millis(300)), None);
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
        let pid = std::fs::read_to_string(&pidfile).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert!(!alive(&pid), "descendant {pid} outlived the timeout");
    }

    #[test]
    fn what_a_profile_leaves_running_is_left_running() {
        let dir = TempDir::new("agent-daemon");
        let pidfile = dir.path().join("pid");
        let answered = sh(&format!(
            "sleep 30 </dev/null >/dev/null 2>&1 & echo $! > '{}'; \
             printf '__herdx_ssh_auth_sock__/tmp/a__herdx_ssh_auth_sock__'",
            pidfile.display()
        ));
        assert!(framed_output(answered, std::time::Duration::from_secs(5)).is_some());
        let pid = std::fs::read_to_string(&pidfile).unwrap();
        let survived = alive(&pid);
        unsafe { libc::kill(pid.trim().parse().unwrap(), libc::SIGKILL) };
        assert!(survived);
    }

    #[test]
    fn a_profile_that_will_not_stop_talking_is_cut_off() {
        let started = std::time::Instant::now();
        assert_eq!(framed_output(sh("yes"), std::time::Duration::from_secs(5)), None);
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }

    /// Each cache test gets its own static, so its own fake shell.
    macro_rules! fake_agent_cache {
        ($cache:ident, $answer:ident, $asked:ident, $delay:expr, $refresh:expr, $retry:expr) => {
            static $answer: std::sync::Mutex<Option<std::ffi::OsString>> =
                std::sync::Mutex::new(None);
            static $asked: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            static $cache: AgentCache = AgentCache::new(
                || {
                    $asked.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    std::thread::sleep($delay);
                    $answer.lock().unwrap().clone()
                },
                $refresh,
                $retry,
            );
        };
    }

    /// A shell that confidently prints a path to nothing.
    ///
    /// Taken as a success it cleared the retry cooldown, and `get` then threw
    /// it away for not existing and asked again immediately — a login shell
    /// per turn, forever, and `start_ssh` never reached. A machine whose key
    /// needs no agent at all could not connect while a stale `SSH_AUTH_SOCK`
    /// sat in somebody's profile.
    #[test]
    fn a_socket_that_is_not_there_is_a_failed_lookup_not_a_spin() {
        use std::time::Duration;
        fake_agent_cache!(
            CACHE, ANSWER, ASKED, Duration::ZERO, Duration::from_secs(600),
            Duration::from_secs(600)
        );
        *ANSWER.lock().unwrap() = Some("/nonexistent/herdx-agent.sock".into());

        let started = std::time::Instant::now();
        assert_eq!(CACHE.get(&|| false), None, "a path to nothing was handed to ssh");
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "took {:?}; the loop never gave up",
            started.elapsed()
        );

        // And it is now under the cooldown rather than asked again at once.
        let before = ASKED.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(CACHE.get(&|| false), None);
        assert_eq!(
            ASKED.load(std::sync::atomic::Ordering::SeqCst),
            before,
            "the unusable answer was looked for again inside the cooldown"
        );
    }

    #[test]
    fn an_agent_that_went_away_is_looked_for_again() {
        use std::time::Duration;
        fake_agent_cache!(CACHE, ANSWER, ASKED, Duration::ZERO, Duration::from_secs(600), Duration::ZERO);
        let dir = TempDir::new("agent-moved");
        let old = dir.path().join("old.sock");
        let new = dir.path().join("new.sock");
        std::fs::write(&old, "").unwrap();
        std::fs::write(&new, "").unwrap();

        *ANSWER.lock().unwrap() = Some(old.clone().into());
        assert_eq!(CACHE.get(&|| false), Some(old.clone().into()));
        std::fs::remove_file(&old).unwrap();
        *ANSWER.lock().unwrap() = Some(new.clone().into());
        assert_eq!(CACHE.get(&|| false), Some(new.into()));
    }

    #[test]
    fn an_old_answer_is_refreshed_without_waiting_for_it() {
        use std::time::Duration;
        fake_agent_cache!(CACHE, ANSWER, ASKED, Duration::ZERO, Duration::ZERO, Duration::ZERO);
        let dir = TempDir::new("agent-refresh");
        let old = dir.path().join("old.sock");
        let new = dir.path().join("new.sock");
        std::fs::write(&old, "").unwrap();
        std::fs::write(&new, "").unwrap();

        *ANSWER.lock().unwrap() = Some(old.clone().into());
        assert_eq!(CACHE.get(&|| false), Some(old.clone().into()));
        *ANSWER.lock().unwrap() = Some(new.clone().into());
        // Still usable, so handed out while the refresh runs...
        assert_eq!(CACHE.get(&|| false), Some(old.into()));
        std::thread::sleep(Duration::from_millis(200));
        // ...and replaced once it lands.
        assert_eq!(CACHE.get(&|| false), Some(new.into()));
    }

    #[test]
    fn a_failure_is_retried_but_not_at_once() {
        use std::sync::atomic::Ordering;
        use std::time::Duration;
        fake_agent_cache!(CACHE, ANSWER, ASKED, Duration::ZERO, Duration::from_secs(600), Duration::from_millis(300));
        let dir = TempDir::new("agent-retry");
        let agent = dir.path().join("agent.sock");
        std::fs::write(&agent, "").unwrap();

        assert_eq!(CACHE.get(&|| false), None);
        *ANSWER.lock().unwrap() = Some(agent.clone().into());
        assert_eq!(CACHE.get(&|| false), None, "retried inside the cooldown");
        assert_eq!(ASKED.load(Ordering::SeqCst), 1);
        std::thread::sleep(Duration::from_millis(350));
        assert_eq!(CACHE.get(&|| false), Some(agent.into()));
        assert_eq!(ASKED.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_connection_can_stop_waiting_for_a_slow_shell() {
        use std::time::Duration;
        fake_agent_cache!(CACHE, ANSWER, ASKED, Duration::from_secs(3), Duration::from_secs(600), Duration::ZERO);
        let started = std::time::Instant::now();
        let cancel_at = started + Duration::from_millis(100);
        assert_eq!(CACHE.get(&|| std::time::Instant::now() >= cancel_at), None);
        assert!(started.elapsed() < Duration::from_millis(500));
    }
}
