#!/usr/bin/env bash
# fm-lock-lib.sh - the per-home helm: which session may DRIVE this firstmate home.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4 (same-home collision).
#
# THE LOCK GUARDS MUTATION, NOT ACTIVATION.
#
# A second firstmate session on the same home activates fully: same fleet view,
# answers "what is the fleet doing", reads any project, reasons, drafts. It is an
# OBSERVER, not an error. It is refused only when it tries to spawn, steer, tear
# down or merge, and only at the moment that verb is asked for - never at boot.
# Several sessions on one home is the NORMAL case, so a boot-time banner would
# fire constantly and train the captain to ignore it. That is the whole design,
# and the presentation is the point: no banner, no red text, no error string at
# boot. Section 4 rules out a boot-time refusal explicitly.
#
# WHICH SCRIPTS GATE, and why the others do not, is documented once in
# docs/scripts.md ("The helm: which verbs gate on the session lock"). This file
# supplies the check; it does not decide the roster.
#
# Source this; do not execute it. It is SIDE-EFFECT FREE - it creates no
# directories and writes no files - so bin/fm-lock.sh can source it and still
# relay `status` from the read-only boot emitter (gate m2 asserts a full boot
# writes nothing).

# Known harness command names; extend when a new adapter is verified. Single
# owner: bin/fm-lock.sh sources this rather than keeping its own copy.
FM_LOCK_HARNESS_RE='claude|codex|opencode|^pi$'

fm_lock_file() {  # <state-dir>
  printf '%s/.lock\n' "$1"
}

# The harness (agent) process pid for THIS session, found by walking the shell's
# ancestry. It lives as long as the firstmate session, unlike the transient
# subshell pid of any one tool call, which is dead moments after it is written.
# Returns 1 when no harness can be identified in the ancestry.
fm_lock_harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_LOCK_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_LOCK_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

fm_lock_holder_alive() {  # <pid> - true if it is a live process that looks like a harness
  local pid=$1 comm
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_LOCK_HARNESS_RE"
}

fm_lock_holder() {  # <state-dir> -> prints the recorded holder pid; 1 when the lock is free
  local lock holder
  lock=$(fm_lock_file "$1")
  [ -f "$lock" ] || return 1
  holder=$(cat "$lock" 2>/dev/null || true)
  [ -n "$holder" ] || return 1
  printf '%s\n' "$holder"
}

# fm_lock_require_helm <state-dir> <label>
#
# The writer-only seam. Returns 0 - the caller proceeds - unless ANOTHER live
# harness holds this home's lock. Callers use `|| exit 1` so the refusal is a
# stop, not a warning: this is deliberately NOT bin/fm-guard.sh, which always
# exits 0 by design and is the wrong place to enforce anything.
#
# Four ways to be allowed through, and each one means "nobody else is steering":
#   free      - no lock file, or an empty one
#   stale     - the recorded holder is dead, or is no longer a harness
#   ours      - the recorded holder is this session's own harness
#   unknown   - this session's harness cannot be identified at all (see below)
#
# EDGE POLICY, harness-not-found. fm_lock_harness_pid can fail to identify a
# harness in the ancestry - an unverified adapter, a wrapper, a shell invoked
# outside any agent. It FAILS OPEN, out loud on stderr. Failing closed would be a
# lock-out by another route: a session that cannot name its own harness could
# never prove it is the holder, so it could never drive, and --take would not
# help because the fault is not with the holder. An unidentifiable harness must
# not silently block writes, so it does not block them - and it does not do that
# silently either.
#
# THERE IS NO ENV BYPASS, deliberately. The escape hatch is `fm-lock.sh --take`,
# permitted only when the holder is provably dead. An env override would let a
# session drive while another genuinely steers, which is the one outcome this
# seam exists to prevent.
fm_lock_require_helm() {
  local state=$1 label=$2 holder me
  holder=$(fm_lock_holder "$state") || return 0
  fm_lock_holder_alive "$holder" || return 0
  if ! me=$(fm_lock_harness_pid); then
    echo "note: $label proceeding - cannot identify this session's harness, so the helm check is skipped (lock held by pid $holder)" >&2
    return 0
  fi
  [ "$me" != "$holder" ] || return 0
  {
    echo "refused: $label - another live session holds this home's helm (harness pid $holder)."
    echo "say to the captain: Another session is steering this home right now, so I'm reading rather than driving. Say the word if you want me to take the helm."
    echo "if that session has ended: bin/fm-lock.sh --take (permitted only when the holder is provably dead)"
  } >&2
  return 1
}
