#!/usr/bin/env bash
# Acquire, take, or inspect the per-home firstmate session lock - the HELM.
#
# The lock guards MUTATION, NOT ACTIVATION. A second session on this home boots
# fully and reads everything; it is refused only at a drive verb, and only when
# it asks for one. The check itself lives in bin/fm-lock-lib.sh
# (fm_lock_require_helm); this script owns acquiring and reporting.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh --take    take the helm from a holder that is provably dead
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# ATOMICITY. Acquire is a compare-and-swap - read the holder, judge it, write
# ours - and those three steps must be indivisible or two sessions racing could
# both conclude they hold the helm. They are serialised by fm_lock_try_acquire
# (bin/fm-wake-lib.sh) held over the whole critical section on
# $STATE/.lock.acquire. That primitive is this repo's existing atomic mutex: an
# atomic `ln -s` create, with dead-owner reclamation itself serialised through a
# second lock, and tests/fm-watcher-lock.test.sh already proves exactly one
# winner under 40-way concurrency, on a free lock and on a stale one. Reusing it
# is deliberate - a second CAS implementation is a second thing to get wrong.
#
# --take IS THE ONLY ESCAPE HATCH, and it is permitted only when the holder is
# provably dead. There is deliberately no force-evict flag and no env bypass: a
# live holder is never evicted without the captain's explicit word, and the
# captain's word means ending that session, which is a human action and not
# something a script may do on its own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
LOCK=$(fm_lock_file "$STATE")
# $STATE is deliberately NOT created here. `status` is relayed verbatim into the
# boot context by the read-only emitter (bin/fm-boot-context.sh), and a reporting
# path that creates a directory is not read-only. The acquire path below makes
# the dir; status only reads. Gate m2 asserts a full boot writes nothing.

TAKE=0
case "${1:-}" in
  status)
    if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
    old=$(cat "$LOCK")
    if fm_lock_holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
    exit 0
    ;;
  --take) TAKE=1 ;;
  '') : ;;
  *) echo "usage: fm-lock.sh [status|--take]" >&2; exit 1 ;;
esac

mkdir -p "$STATE"
me=$(fm_lock_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }

# The critical section's mutex. Sourced here rather than at the top so `status`
# above stays read-only: fm-wake-lib.sh creates $STATE at source time.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
MUTEX="$STATE/.lock.acquire"
# ~3s of contention before giving up. Bounded rather than unbounded so a wedged
# peer cannot hang a boot; FM_LOCK_ACQUIRE_TRIES shortens it for tests.
ACQUIRE_TRIES=${FM_LOCK_ACQUIRE_TRIES:-30}
tries=0
until fm_lock_try_acquire "$MUTEX"; do
  tries=$((tries + 1))
  if [ "$tries" -ge "$ACQUIRE_TRIES" ]; then
    echo "error: could not serialise the lock acquire (mutex $MUTEX busy); retry" >&2
    exit 1
  fi
  sleep 0.1
done
trap 'fm_lock_release "$MUTEX"' EXIT

old=
[ -f "$LOCK" ] && old=$(cat "$LOCK" 2>/dev/null || true)

if [ -n "$old" ] && [ "$old" != "$me" ] && fm_lock_holder_alive "$old"; then
  if [ "$TAKE" = 1 ]; then
    {
      echo "refused: --take - pid $old is a LIVE harness, and a live holder is never evicted without the captain's word."
      echo "say to the captain: Another session is steering this home right now, so I'm reading rather than driving. Say the word if you want me to take the helm."
      echo "taking the helm means ending that session first; then run: bin/fm-lock.sh --take"
    } >&2
    exit 1
  fi
  {
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved"
    echo "say to the captain: Another session is steering this home right now, so I'm reading rather than driving. Say the word if you want me to take the helm."
    echo "if that session has ended: bin/fm-lock.sh --take (permitted only when the holder is provably dead)"
  } >&2
  exit 1
fi

printf '%s\n' "$me" > "$LOCK"

if [ "$TAKE" = 1 ]; then
  if [ -n "$old" ] && [ "$old" != "$me" ]; then
    echo "helm taken: harness pid $me (from dead pid $old)"
  elif [ "$old" = "$me" ]; then
    echo "helm held: harness pid $me (already ours)"
  else
    echo "helm taken: harness pid $me (the lock was free)"
  fi
  exit 0
fi

if [ -n "$old" ] && [ "$old" != "$me" ]; then
  echo "lock acquired: harness pid $me (reclaimed from dead pid $old)"
else
  echo "lock acquired: harness pid $me"
fi
