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
    pub fn connect(
        endpoint: &Endpoint,
        socket: &std::path::Path,
    ) -> io::Result<(ReadHalf, WriteHalf, Interrupt)> {
        match &endpoint.kind {
            EndpointKind::Local => {
                let stream = std::os::unix::net::UnixStream::connect(socket)?;
                let writer = stream.try_clone()?;
                let interrupt = Interrupt::Local(stream.try_clone()?);
                Ok((ReadHalf::Local(stream), WriteHalf::Local(writer), interrupt))
            }
            EndpointKind::Ssh { target, session } => start_ssh(target, session),
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

fn start_ssh(target: &str, session: &str) -> io::Result<(ReadHalf, WriteHalf, Interrupt)> {
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
        .arg(remote_bridge_command(session));
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
}
