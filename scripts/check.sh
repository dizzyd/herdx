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

# After bundle.sh, which is what builds libherdr_core.a: the test bundle links
# it through the same raw -L flag the app does, so it has to exist first.
echo "==> swift test"
CONFIG="${1:-debug}"
if [ "${HERDX_UNIVERSAL:-0}" = 1 ]; then
  CORE_LIB_DIR="$ROOT/target/universal/$CONFIG"
else
  CORE_LIB_DIR="$ROOT/target/$CONFIG"
fi
(cd "$ROOT/HerdX" && HERDX_CORE_LIB_DIR="$CORE_LIB_DIR" swift test -c "$CONFIG")

echo "OK"
