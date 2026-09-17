//! Records which herdr build the vendored sources came from.
//!
//! The surface lane rides herdr's *private* bincode protocol, whose variant
//! tags are positional, so a client has to be able to tell whether it is
//! decoding frames from the build it was compiled against. Reading the version
//! out of the submodule at build time keeps that honest automatically.

use std::path::Path;

fn main() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../vendor/herdr/Cargo.toml");
    println!("cargo:rerun-if-changed={}", manifest.display());

    let version = std::fs::read_to_string(&manifest)
        .ok()
        .and_then(|text| parse_package_version(&text))
        .unwrap_or_else(|| {
            panic!(
                "could not read a version from {}; run `git submodule update --init`",
                manifest.display()
            )
        });
    println!("cargo:rustc-env=HERDR_VENDORED_VERSION={version}");

    let protocol = Path::new(env!("CARGO_MANIFEST_DIR")).join("../vendor/herdr/src/protocol/wire.rs");
    println!("cargo:rerun-if-changed={}", protocol.display());
}

/// Takes `version` from the `[package]` table, ignoring any that follow.
fn parse_package_version(manifest: &str) -> Option<String> {
    let mut in_package = false;
    for line in manifest.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
            continue;
        }
        if in_package {
            if let Some(rest) = line.strip_prefix("version") {
                let value = rest.trim_start().strip_prefix('=')?.trim();
                return Some(value.trim_matches('"').to_owned());
            }
        }
    }
    None
}
