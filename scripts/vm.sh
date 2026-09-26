#!/usr/bin/env bash
#
# A Mac that has never heard of herdr.
#
# Some of this app's behaviour only exists on a machine where herdr is not
# installed — the first-run dialog, the empty terminal that has to explain
# itself, the window starting a server of its own. None of it can be produced
# on a developer's Mac, because a developer's Mac has herdr on it, and the one
# environment variable that looks like it would help does not: `HERDR_CONFIG_DIR`
# does not isolate the CLI (see AGENTS.md), so faking it aims a test run at the
# real session. A throwaway VM is the only honest way to see any of it.
#
#   ./scripts/vm.sh create      clone the base image and size it
#   ./scripts/vm.sh boot        start it, headless, and wait for ssh
#   ./scripts/vm.sh install     bundle on this Mac and copy the app in
#   ./scripts/vm.sh capture <out.png> [VAR=VAL …]   photograph a run, bring it back
#   ./scripts/vm.sh exec <cmd…> run something in the guest
#   ./scripts/vm.sh snapshot    keep this state
#   ./scripts/vm.sh restore     go back to it — this is how you get "fresh" back
#   ./scripts/vm.sh stop        shut it down
#
# CAPTURE IN THE GUEST, not from the host. HerdX renders its own window with
# `HERDX_CAPTURE`, which needs no window server permission and never puts
# anything on a screen. Filming the VM's window from the host would need the
# guest in front on somebody's real display, which is the thing this whole
# arrangement exists to avoid.
#
set -euo pipefail

VM_NAME="${HERDX_VM:-herdx-fresh}"
BASE="${HERDX_VM_BASE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
SNAP="${VM_NAME}-clean"
USER_NAME="admin"
PASS="admin"
# The guest's GUI login session. An AppKit app started from ssh has no window
# server to talk to and dies before `main`; `launchctl asuser` is the way in,
# and it is uid-keyed, so this is the number rather than the name.
GUI_UID=501

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# PubkeyAuthentication off and IdentitiesOnly on, because ssh offers every key
# the agent holds before it will try a password, and a developer with more than
# five of them is disconnected for "too many authentication failures" before the
# password is ever sent. Nothing here wants a key.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o PubkeyAuthentication=no -o IdentitiesOnly=yes
  -o PreferredAuthentications=password -o LogLevel=ERROR -o ConnectTimeout=60)

need() { command -v "$1" >/dev/null || { echo "missing: $1 — brew install $2" >&2; exit 1; }; }

vm_ip() { tart ip "$VM_NAME" --wait 120; }

ssh_vm() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER_NAME@$(vm_ip)" "$@"; }
scp_to() { sshpass -p "$PASS" scp -r "${SSH_OPTS[@]}" "$1" "$USER_NAME@$(vm_ip):$2"; }
scp_from() { sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$USER_NAME@$(vm_ip):$1" "$2"; }

case "${1:-}" in

create)
  need tart tart
  need sshpass sshpass
  if tart list | grep -q " ${VM_NAME} "; then
    echo "$VM_NAME already exists — ./scripts/vm.sh restore puts it back to the snapshot"
    exit 1
  fi
  tart clone "$BASE" "$VM_NAME"
  # Modest on purpose: this runs beside whatever the developer is actually
  # doing, and nothing here is a build.
  tart set "$VM_NAME" --cpu 4 --memory 4096 --display 1440x900pt
  echo "created $VM_NAME — now: ./scripts/vm.sh boot"
  ;;

boot)
  need sshpass sshpass
  if tart list | grep -q " ${VM_NAME} .*running"; then
    echo "already running at $(vm_ip)"
    exit 0
  fi
  # Detached and without a window. A VM window on the developer's display is
  # the same interruption as the app's own window would be.
  nohup tart run "$VM_NAME" --no-graphics >"${TMPDIR:-/tmp}/$VM_NAME.log" 2>&1 &
  echo "booting…"
  ssh_vm true
  echo "up at $(vm_ip)"
  ;;

install)
  need sshpass sshpass
  "$ROOT/scripts/bundle.sh" "${2:-debug}" >/dev/null
  # Cleared first: `scp -r` into a path that already exists copies *inside* it,
  # so the second install of the day lands at /tmp/HerdX.app/HerdX.app and the
  # app that gets installed is the one from the first. It looks like a build
  # that did not take, and it costs an hour every time.
  ssh_vm "rm -rf /tmp/HerdX.app"
  scp_to "$ROOT/build/HerdX.app" "/tmp/HerdX.app"
  ssh_vm bash -s <<'GUEST'
set -eu
rm -rf /Applications/HerdX.app
cp -R /tmp/HerdX.app /Applications/HerdX.app
# scp does not set com.apple.quarantine — it comes from browsers and
# LaunchServices — but stripping it anyway keeps a first launch from ever
# raising the unidentified-developer sheet, which nothing here could dismiss.
xattr -dr com.apple.quarantine /Applications/HerdX.app 2>/dev/null || true
GUEST
  echo "installed in $VM_NAME"
  ;;

capture)
  need sshpass sshpass
  OUT="${2:?usage: vm.sh capture <out.png> [VAR=VAL …]}"
  shift 2
  # `env` rather than a prefix assignment, because this crosses into the login
  # session through two sudos and a plain VAR=x would be eaten by the first.
  ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME env HERDX_CAPTURE=/tmp/shot.png ${*} /Applications/HerdX.app/Contents/MacOS/HerdX"
  scp_from "/tmp/shot.png" "$OUT"
  echo "$OUT"
  ;;

exec)
  need sshpass sshpass
  shift
  ssh_vm "$@"
  ;;

gui)
  # Anything that has to happen inside the login session rather than beside it.
  need sshpass sshpass
  shift
  ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME $*"
  ;;

snapshot)
  # Flushed and shut down properly before the copy. A `tart stop` that runs out
  # of patience pulls the plug, and what the guest had not written is simply not
  # in the snapshot — an app installed a minute earlier comes back missing, from
  # a VM that looks fine.
  ssh_vm "sync" 2>/dev/null || true
  ssh_vm "sudo shutdown -h now" 2>/dev/null || true
  for _ in $(seq 60); do
    tart list | grep -q " ${VM_NAME} .*running" || break
    sleep 1
  done
  tart stop "$VM_NAME" --timeout 60 2>/dev/null || true
  tart delete "$SNAP" 2>/dev/null || true
  tart clone "$VM_NAME" "$SNAP"
  echo "snapshot: $SNAP"
  ;;

restore)
  # The copy is made before the original is touched, and made under another
  # name so a clone that fails half way cannot leave the working VM deleted and
  # nothing in its place. Stopping and deleting first is how `restore` came to
  # be a way of destroying a VM when no snapshot had ever been taken — which is
  # exactly what `create` suggests running when a VM already exists.
  tart get "$SNAP" >/dev/null 2>&1 || {
    echo "no snapshot $SNAP — ./scripts/vm.sh snapshot takes one" >&2
    exit 1
  }
  STAGING="${VM_NAME}-restoring"
  tart delete "$STAGING" 2>/dev/null || true
  tart clone "$SNAP" "$STAGING"
  tart stop "$VM_NAME" --timeout 60 2>/dev/null || true
  tart delete "$VM_NAME" 2>/dev/null || true
  tart rename "$STAGING" "$VM_NAME"
  echo "restored $VM_NAME from $SNAP — ./scripts/vm.sh boot"
  ;;

stop)
  # Asked from inside, so the guest writes everything out; see `snapshot`.
  ssh_vm "sync" 2>/dev/null || true
  tart stop "$VM_NAME" --timeout 60 2>/dev/null || true
  echo "stopped"
  ;;

*)
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
