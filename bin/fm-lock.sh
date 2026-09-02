#!/usr/bin/env bash
# Acquire, take, or inspect the per-home firstmate session lock - the HELM.
#
# The lock guards MUTATION, NOT ACTIVATION. A second session on this home boots
# fully and reads everything; it is stopped only at a drive verb, and only when
# it asks for one. The compare-and-swap and the writer-only seam both live in
# bin/fm-lock-lib.sh (fm_lock_cas, fm_lock_require_helm); this script is the
# operator-facing verb around them, so there is one implementation, not two.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# Records the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# Usage: fm-lock.sh           acquire; report plainly if another live session holds it
#        fm-lock.sh --take    take the helm from a holder that is provably dead
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# THE BARE ACQUIRE IS A BOOT COMMAND, so it must not read as an error. AGENTS.md
# section 5 makes it recovery step 1 of every session, and section 4 of the spec
# is explicit: no banner, no red text, no error string at boot. Finding another
# session already steering is the NORMAL outcome for the second instance, so it
# is reported as a plain fact and exits 0. The captain-facing sentence is not
# said here either - it belongs at the moment the captain asks for a drive verb,
# which is where fm_lock_require_helm says it.
#
# --take IS THE ONLY ESCAPE HATCH, and it is permitted only when the holder is
# provably dead. There is deliberately no force-evict flag: a live holder is
# never evicted without the captain's explicit word, and that word means ending
# the other session, which is a human action and not something a script may do.
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

# One compare-and-swap, shared with the seam. bin/fm-lock-lib.sh owns it,
# including the mutex that makes it indivisible.
fm_lock_cas "$STATE" "$me"; rc=$?

if [ "$rc" -eq 2 ]; then
  echo "error: could not serialise the lock acquire (mutex $STATE/.lock.acquire busy); retry" >&2
  exit 1
fi

if [ "$rc" -eq 1 ]; then
  if [ "$TAKE" = 1 ]; then
    {
      echo "refused: --take - pid $FM_LOCK_HELD_BY is a LIVE harness, and a live holder is never evicted without the captain's word."
      echo "say to the captain: Another session is steering this home right now, so I'm reading rather than driving. Say the word if you want me to take the helm."
      echo "taking the helm means ending that session first; then run: bin/fm-lock.sh --take"
    } >&2
    exit 1
  fi
  # Boot path. A plain fact, not a refusal, and exit 0 - see the header.
  echo "lock: held by another live session (harness pid $FM_LOCK_HELD_BY) - this session is observing, not steering"
  exit 0
fi

if [ "$TAKE" = 1 ]; then
  if [ -n "$FM_LOCK_PREVIOUS" ]; then
    echo "helm taken: harness pid $me (from dead pid $FM_LOCK_PREVIOUS)"
  else
    echo "helm held: harness pid $me (it was already ours, or free)"
  fi
  exit 0
fi

if [ -n "$FM_LOCK_PREVIOUS" ]; then
  echo "lock acquired: harness pid $me (reclaimed from dead pid $FM_LOCK_PREVIOUS)"
else
  echo "lock acquired: harness pid $me"
fi
