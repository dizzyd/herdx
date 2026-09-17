//! Compatibility guards for the vendored herdr protocol.
//!
//! herdr's own `#[cfg(test)]` modules cannot compile here (they reach into the
//! PTY-backed terminal runtime), so these tests re-assert the parts of the
//! contract this client actually depends on, using herdr's own frozen
//! generation-1 fixtures from the pinned submodule.

use herdr_protocol::protocol::endpoint::{
    EndpointClientHello, EndpointServerWelcome, ENDPOINT_PROTOCOL_GENERATION, INPUT_CODEC_V1,
    SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
};
use herdr_protocol::protocol::{
    read_message, write_message, ClientMessage, ClientShellSnapshot, MAX_FRAME_SIZE,
};

// ---------------------------------------------------------------------------
// Frozen generation-1 endpoint fixtures
// ---------------------------------------------------------------------------

#[test]
fn frozen_hello_fixture_decodes_and_advertises_required_codecs() {
    let hello: EndpointClientHello =
        serde_json::from_str(include_str!("fixtures/endpoint-hello-v1.json")).unwrap();
    assert_eq!(hello.generation, ENDPOINT_PROTOCOL_GENERATION);
    assert!(
        hello.supports_required_codecs(),
        "generation-1 hello must still satisfy the required codec set"
    );
}

#[test]
fn frozen_welcome_fixture_decodes_with_expected_codecs() {
    let welcome: EndpointServerWelcome =
        serde_json::from_str(include_str!("fixtures/endpoint-welcome-v1.json")).unwrap();
    assert_eq!(welcome.generation, ENDPOINT_PROTOCOL_GENERATION);
    assert_eq!(welcome.snapshot_codec, SNAPSHOT_CODEC_V1);
    assert_eq!(welcome.surface_codec, SURFACE_CODEC_V1);
    assert_eq!(welcome.input_codec, INPUT_CODEC_V1);
}

#[test]
fn frozen_snapshot_fixture_decodes() {
    let snapshot: ClientShellSnapshot =
        serde_json::from_str(include_str!("fixtures/endpoint-snapshot-v1.json")).unwrap();
    assert_eq!(snapshot.boot_id, "boot-v1");
}

/// The snapshot is the client's whole model of the workspace/tab/pane/agent
/// tree, so unknown future fields must stay non-fatal.
#[test]
fn snapshot_tolerates_unknown_future_fields() {
    let mut value: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/endpoint-snapshot-v1.json")).unwrap();
    value["future_projection"] = serde_json::json!({ "enabled": true });
    serde_json::from_value::<ClientShellSnapshot>(value)
        .expect("a generation-1 client must ignore fields added by newer servers");
}

// ---------------------------------------------------------------------------
// Wire framing
// ---------------------------------------------------------------------------

/// `EndpointControl` is the one `ClientMessage` variant herdr documents as
/// append-only and frozen for endpoint generation 1. Its bincode tag and
/// two-string payload are the foundation the whole stable contract rests on, so
/// pin the exact bytes rather than merely round-tripping them.
#[test]
fn endpoint_control_frame_layout_is_frozen() {
    let mut buf = Vec::new();
    write_message(
        &mut buf,
        &ClientMessage::EndpointControl {
            kind: "a".into(),
            data: "b".into(),
        },
    )
    .unwrap();

    assert_eq!(
        buf,
        vec![
            5, 0, 0, 0, // u32-LE payload length
            20,   // bincode variant tag for ClientMessage::EndpointControl
            1, b'a', // kind: varint length + UTF-8
            1, b'b', // data: varint length + UTF-8
        ],
        "the frozen EndpointControl framing changed; \
         a generation-1 server will no longer understand this client"
    );
}

#[test]
fn endpoint_control_round_trips_through_framing() {
    let message = ClientMessage::EndpointControl {
        kind: "endpoint.hello.v1".into(),
        data: r#"{"generation":1}"#.into(),
    };
    let mut buf = Vec::new();
    write_message(&mut buf, &message).unwrap();

    let decoded: ClientMessage = read_message(&mut buf.as_slice(), MAX_FRAME_SIZE).unwrap();
    assert_eq!(decoded, message);
}

#[test]
fn oversized_frames_are_rejected() {
    let message = ClientMessage::EndpointControl {
        kind: "k".into(),
        data: "d".into(),
    };
    let mut buf = Vec::new();
    write_message(&mut buf, &message).unwrap();

    read_message::<_, ClientMessage>(&mut buf.as_slice(), 2)
        .expect_err("a frame larger than the cap must be refused, not truncated");
}

// ---------------------------------------------------------------------------
// Drift alarms for the local shims
// ---------------------------------------------------------------------------

mod shim_parity {
    use herdr_protocol::detect::{agent_label, Agent};

    /// The vendored module our `detect` shim mirrors.
    const UPSTREAM: &str = include_str!("upstream/detect_mod.rs");

    fn upstream_variants() -> Vec<String> {
        let body = UPSTREAM
            .split_once("pub enum Agent {")
            .expect("upstream still declares `pub enum Agent`")
            .1
            .split_once('}')
            .expect("unterminated enum")
            .0;
        body.lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("//"))
            .map(|line| line.trim_end_matches(',').to_owned())
            .collect()
    }

    #[test]
    fn agent_variants_match_upstream() {
        let ours: Vec<String> = Agent::ALL.iter().map(|a| format!("{a:?}")).collect();
        assert_eq!(
            ours,
            upstream_variants(),
            "vendor/herdr changed its Agent list; update the shim in src/detect.rs"
        );
    }

    #[test]
    fn agent_labels_match_upstream() {
        let body = UPSTREAM
            .split_once("pub fn agent_label(agent: Agent) -> &'static str {")
            .expect("upstream still declares `agent_label`")
            .1;
        for agent in Agent::ALL {
            let needle = format!("Agent::{agent:?} => \"{}\",", agent_label(agent));
            assert!(
                body.contains(&needle),
                "label for {agent:?} no longer matches upstream: expected `{needle}`"
            );
        }
    }
}
