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
#   ./scripts/vm.sh lockcheck  prove a locked screen silences the agent sounds
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

# One shell-quoted word per argument. ssh hands what it is given to a shell at
# the far end, so an unquoted `HERDX_PROBE_INPUT=echo hello` arrives as two
# words: `env` takes the assignment and then tries to run `hello`. Quotes,
# dollars and semicolons go the same way, only less visibly.
quote() {
  local out="" arg
  for arg in "$@"; do out="$out $(printf '%q' "$arg")"; done
  printf '%s' "$out"
}

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
  # Until it answers, not once: a guest hands out its IP before sshd is
  # listening, and the refusal that comes back in between is instant. One
  # attempt turns "still booting" into a failed command and, under `set -e`,
  # into an abandoned boot.
  deadline=$(( $(date +%s) + 300 ))
  until ssh_vm true 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "$VM_NAME never answered ssh" >&2
      exit 1
    fi
    sleep 2
  done
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
  ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME env HERDX_CAPTURE=/tmp/shot.png $(quote "$@") /Applications/HerdX.app/Contents/MacOS/HerdX"
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
  ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME $(quote "$@")"
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

lockcheck)
  # Does a locked screen really silence the agent sounds?
  #
  # The unit tests answer what `isAudible` does with a given reading. What they
  # cannot answer is whether a real lock produces that reading, because the one
  # moment nothing can be read off a screen is while it is locked — and locking
  # the developer's screen to find out is not on. Locking this guest's costs
  # nobody anything.
  #
  # Reads the probe's own transcript rather than trusting the sequence of
  # commands that produced it: `open -a ScreenSaverEngine` returning 0 says the
  # engine started, not that the session locked.
  #
  # The lock policy is turned on to lock and off again to unlock, and that
  # order is the whole trick. A guest left on `immediate` locks again the
  # instant its login session is rebuilt, so unlocking never takes — and since
  # a headless VM has no display to unlock by hand, one run that forgets leaves
  # a guest that reads locked for good and a `restore` to get out of it.
  need sshpass sshpass
  RUN=30 LOCK_AT=7 UNLOCK_AT=18

  # An idle screen saver would lock the session on its own schedule, and then
  # this measures nothing: the only lock in the transcript has to be ours.
  ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME \
            defaults -currentHost write com.apple.screensaver idleTime -int 0
          sudo sysadminctl -screenLock off -password $PASS >/dev/null 2>&1 || true
          sudo pkill ScreenSaverEngine 2>/dev/null || true"

  # Ask whether the session is unlocked rather than sleeping and hoping. A
  # guest that starts locked would fail the first window for a reason that has
  # nothing to do with the app, which is worse than no test at all.
  read_lock() {
    ssh_vm "rm -f /tmp/lockstate.log
      nohup sudo launchctl asuser $GUI_UID sudo -u $USER_NAME \
        env HERDX_HEADLESS=1 HERDX_PROBE_LOCK=1 \
        /Applications/HerdX.app/Contents/MacOS/HerdX > /tmp/lockstate.log 2>&1 &
      sleep 4
      sudo pkill -f 'MacOS/HerdX' 2>/dev/null || true
      grep -o 'locked=[a-z]*' /tmp/lockstate.log | head -1" 2>/dev/null || true
  }

  # A locked guest is put back rather than argued with. Nothing can unlock a
  # headless VM — there is no screen to type a password at — and rebuilding the
  # login session, which works while the screen saver is up, does not once the
  # run is over. So a guest that starts locked goes back to the snapshot, which
  # is what the snapshot is for and what makes this repeatable rather than a
  # thing that works once.
  state="$(read_lock)"
  if [ "$state" != "locked=false" ]; then
    echo "lockcheck: guest reads ${state:-nothing} — restoring, this takes a few minutes"
    tart get "$SNAP" >/dev/null 2>&1 || {
      echo "lockcheck: no snapshot $SNAP to go back to — ./scripts/vm.sh snapshot" >&2
      exit 1
    }
    "$0" restore
    "$0" boot
    "$0" install
    ssh_vm "sudo launchctl asuser $GUI_UID sudo -u $USER_NAME \
              defaults -currentHost write com.apple.screensaver idleTime -int 0
            sudo sysadminctl -screenLock off -password $PASS >/dev/null 2>&1 || true"
    state="$(read_lock)"
  fi
  if [ "$state" != "locked=false" ]; then
    echo "lockcheck: the guest will not come back unlocked (last read: ${state:-nothing})" >&2
    exit 1
  fi

  ssh_vm "sudo pkill -f 'MacOS/HerdX' 2>/dev/null; rm -f /tmp/lock.log
    nohup sudo launchctl asuser $GUI_UID sudo -u $USER_NAME \
      env HERDX_HEADLESS=1 HERDX_PROBE_LOCK=$RUN \
      /Applications/HerdX.app/Contents/MacOS/HerdX > /tmp/lock.log 2>&1 &
    sleep $LOCK_AT
    sudo sysadminctl -screenLock immediate -password $PASS >/dev/null 2>&1
    sudo launchctl asuser $GUI_UID sudo -u $USER_NAME open -a ScreenSaverEngine
    sleep $((UNLOCK_AT - LOCK_AT))
    # Off first: a session rebuilt while this is still immediate comes back
    # locked, and then nothing can unlock it.
    sudo sysadminctl -screenLock off -password $PASS >/dev/null 2>&1
    sudo pkill ScreenSaverEngine 2>/dev/null || true
    sudo killall loginwindow 2>/dev/null || true
    sleep $((RUN - UNLOCK_AT + 8))
    sudo pkill -f 'MacOS/HerdX' 2>/dev/null || true" || true
  # Rebuilding the login session drops ssh for a moment.
  for _ in $(seq 12); do ssh_vm "true" 2>/dev/null && break; sleep 5; done

  LOG="${2:-$ROOT/build/lockcheck.log}"
  mkdir -p "$(dirname "$LOG")"
  scp_from "/tmp/lock.log" "$LOG"

  # One `t audible` pair per line. Ticks go missing while the login session is
  # being rebuilt, so every window below asks what the samples in it say, not
  # that a sample arrived for each second.
  SAMPLES="$(awk '/^probe: t=/ { t = $2; sub(/^t=/, "", t); sub(/s$/, "", t)
                                 split($4, a, "="); print t, a[2] }' "$LOG")"
  [ -n "$SAMPLES" ] || { echo "lockcheck: the probe said nothing — see $LOG" >&2; exit 1; }

  # window <lo> <hi> <expected> <what it means>
  window() {
    local lo=$1 hi=$2 want=$3 what=$4 seen=0 wrong=0 t a
    while read -r t a; do
      [ "$t" -ge "$lo" ] && [ "$t" -le "$hi" ] || continue
      seen=$((seen + 1))
      [ "$a" = "$want" ] || wrong=$((wrong + 1))
    done <<<"$SAMPLES"
    if [ "$seen" -eq 0 ]; then
      echo "lockcheck: nothing sampled between ${lo}s and ${hi}s ($what)" >&2
      return 1
    fi
    if [ "$wrong" -ne 0 ]; then
      echo "lockcheck: $wrong of $seen samples in ${lo}-${hi}s are not audible=$want ($what)" >&2
      return 1
    fi
    echo "  ${lo}-${hi}s audible=$want over $seen samples — $what"
  }

  FAILED=0
  echo "lockcheck:"
  window 1 $((LOCK_AT - 1)) true "sounds play with somebody there" || FAILED=1
  # Three seconds for the lock to take, and stopping before the unlock lands.
  window $((LOCK_AT + 3)) $((UNLOCK_AT - 1)) false "a locked screen is silent" || FAILED=1
  window $((UNLOCK_AT + 5)) $RUN true "and they come back when it is not" || FAILED=1

  if [ "$FAILED" -ne 0 ]; then
    echo "lockcheck: FAILED — transcript in $LOG" >&2
    exit 1
  fi
  echo "lockcheck: OK ($LOG)"
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
