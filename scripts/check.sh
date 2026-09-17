#!/usr/bin/env bash
# Builds and tests everything, failing loudly.
#
# Worth having as a script: piping `cargo test` into `grep "test result"` looks
# like a check but is not one — `head`/`grep` exit status hides a compile
# failure, which is how a broken test target survived a commit here once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> cargo test"
cargo test --manifest-path "$ROOT/Cargo.toml" --workspace

echo "==> swift build"
"$ROOT/scripts/bundle.sh" "${1:-debug}"

echo "OK"
