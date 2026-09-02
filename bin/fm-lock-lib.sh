#!/usr/bin/env bash
# fm-lock-lib.sh - the per-home firstmate helm: which session may DRIVE this home.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# THE LOCK GUARDS MUTATION, NOT ACTIVATION.
#
# A second firstmate session on the same home activates fully: same fleet view,
# answers "what is the fleet doing", reads any project, reasons, drafts. It is an
# OBSERVER, not an error. It is stopped only when it tries to spawn, steer, tear
# down or merge, and only at the moment that verb is asked for - never at boot.
# Several sessions on one home is the NORMAL case, so a boot-time banner would
# fire constantly and train the captain to ignore it.
#
# THE SEAM CLAIMS; IT DOES NOT MERELY ASK. An advisory check that returns "go
# ahead" for a free or stale lock without taking it is not a lock: the moment a
# holder dies, two observers both read "free" and both drive. So
# fm_lock_require_helm runs the same compare-and-swap fm-lock.sh does - one
# implementation, fm_lock_cas below - and a drive verb that proceeds on a free or
# stale helm has TAKEN it, atomically, before it returns. Exactly one of N racing
# sessions can win that; the rest are refused.
#
# WHICH SCRIPTS GATE, and why the others do not, is documented once in
# docs/scripts.md ("The helm: which verbs gate on the session lock"). This file
# supplies the mechanism; it does not decide the roster.
#
# Source this; do not execute it. Sourcing is SIDE-EFFECT FREE - no directory is
# created and no file is written - so bin/fm-lock.sh can source it and still
# relay `status` from the read-only boot emitter (gate m2 asserts a full boot
# writes nothing). The mutex library is pulled in lazily, inside fm_lock_cas,
# for the same reason.

FM_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Known harness names. ONE regex, applied to two subjects: a bare command
# basename, and a whole argv string. `pi` therefore cannot be matched as a
# substring - `pip`, `pipenv` and `spider` must not read as a harness - so it
# carries its own word boundaries instead of `^pi$`, which silently matched
# NOTHING once it was applied to anything containing a space. That defect made a
# live `pi` session read as dead, which let an observer past the seam and let
# --take evict a live holder. Extend this list when a new adapter is verified.
FM_LOCK_HARNESS_RE='claude|codex|opencode|(^|[^[:alnum:]_-])pi([^[:alnum:]_-]|$)'

fm_lock_file() {  # <state-dir>
  printf '%s/.lock\n' "$1"
}

# fm_lock_pid_is_harness <pid> - is this a LIVE process that looks like a harness?
# The single predicate. Both the "am I a harness" ancestry walk and the "is the
# holder alive" check ask it, so the two can never disagree again.
fm_lock_pid_is_harness() {
  local pid=$1 comm args
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_LOCK_HARNESS_RE"; then
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_LOCK_HARNESS_RE" && return 0
      ;;
  esac
  return 1
}

# Kept as the named predicate the holder check reads by; same rule, one impl.
fm_lock_holder_alive() { fm_lock_pid_is_harness "$1"; }

# The harness (agent) process pid for THIS session, found by walking the shell's
# ancestry. It lives as long as the firstmate session, unlike the transient
# subshell pid of any one tool call, which is dead moments after it is written.
# Returns 1 when no harness can be identified in the ancestry.
fm_lock_harness_pid() {
  local pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    if fm_lock_pid_is_harness "$pid"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

fm_lock_holder() {  # <state-dir> -> prints the recorded holder pid; 1 when free
  local lock holder
  lock=$(fm_lock_file "$1")
  [ -f "$lock" ] || return 1
  holder=$(cat "$lock" 2>/dev/null || true)
  [ -n "$holder" ] || return 1
  printf '%s\n' "$holder"
}

# fm_lock_cas <state-dir> [<me>] - the one compare-and-swap, three callers
# (fm-lock.sh acquire, fm-lock.sh --take, and the seam below).
#
#   0  the helm is ours. FM_LOCK_PREVIOUS names the dead pid it was reclaimed
#      from, or is empty. With <me> empty nothing is recorded - see the
#      harness-not-found policy in fm_lock_require_helm - but nobody else is
#      steering, which is what the caller needs to know.
#   1  refused: a live harness holds it, named in FM_LOCK_HELD_BY.
#   2  could not serialise; nothing was read or written.
#
# ATOMICITY. Read the holder, judge it, write ours must be indivisible or two
# sessions racing could both conclude they hold the helm. The whole critical
# section is held under fm_lock_try_acquire (bin/fm-wake-lib.sh) on
# $STATE/.lock.acquire - this repo's existing atomic mutex, an atomic `ln -s`
# create with dead-owner reclamation itself serialised through a second lock,
# already proven single-winner under 40-way concurrency by
# tests/fm-watcher-lock.test.sh. A second CAS implementation would be a second
# thing to get wrong.
# shellcheck disable=SC2034  # FM_LOCK_PREVIOUS/FM_LOCK_HELD_BY are read by callers
fm_lock_cas() {
  local state=$1 me=${2:-} lock mutex tries max old
  FM_LOCK_HELD_BY=; FM_LOCK_PREVIOUS=
  lock=$(fm_lock_file "$state")
  mkdir -p "$state" 2>/dev/null || true
  # The mutex primitives, pulled in only when a claim is actually made - sourcing
  # this file must stay side-effect free for the read-only boot relay. READONLY so
  # the library creates no directory of ITS notion of $STATE; we made ours above,
  # and the lock helpers need nothing else. The flag is restored rather than left
  # set, so a caller that sources fm-wake-lib.sh later still gets its state dir.
  if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
    local prev_ro=${FM_WAKE_LIB_READONLY:-}
    FM_WAKE_LIB_READONLY=1
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_LOCK_LIB_DIR/fm-wake-lib.sh"
    FM_WAKE_LIB_READONLY=$prev_ro
  fi
  mutex="$state/.lock.acquire"
  max=${FM_LOCK_ACQUIRE_TRIES:-30}
  tries=0
  until fm_lock_try_acquire "$mutex"; do
    tries=$((tries + 1))
    [ "$tries" -lt "$max" ] || return 2
    sleep 0.1
  done
  old=
  [ -f "$lock" ] && old=$(cat "$lock" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$me" ] && fm_lock_pid_is_harness "$old"; then
    FM_LOCK_HELD_BY=$old
    fm_lock_release "$mutex"
    return 1
  fi
  [ "$old" = "$me" ] || FM_LOCK_PREVIOUS=$old
  [ -n "$me" ] && printf '%s\n' "$me" > "$lock"
  fm_lock_release "$mutex"
  return 0
}

# fm_lock_require_helm <state-dir> <label>
#
# The writer-only seam. Returns 0 - and the caller proceeds - only once this
# session HOLDS the helm for that home. Callers use `|| exit 1` so a refusal is a
# stop, not a warning: this is deliberately NOT bin/fm-guard.sh, which always
# exits 0 by design and is the wrong place to enforce anything.
#
# EDGE POLICY, harness-not-found. fm_lock_harness_pid can fail to identify a
# harness in the ancestry - an unverified adapter, a wrapper, a shell invoked
# outside any agent - and such a session cannot record itself as the holder,
# because there is no session-stable pid to record. The split:
#
#   * NOBODY IS STEERING (free or stale helm): allowed through, out loud on
#     stderr, without claiming. Refusing here would be a lock-out by another
#     route - a session that could never drive anything, with no remedy, since
#     --take also needs an identity. The brief is explicit that an unidentifiable
#     harness must not silently block writes, and this is the case that bites.
#   * ANOTHER LIVE HARNESS IS STEERING: refused. This is not a lock-out by
#     another route; it is the seam doing its job. Waving it through was a
#     BYPASS - any caller could defeat the helm by detaching from its agent - and
#     it is also inconsistent with fm-lock.sh, which has always refused to let a
#     session it cannot name hold the helm at all. One rule: you may drive only
#     while you provably hold the helm.
#
# THERE IS NO OVERRIDE VARIABLE for the seam itself. The escape hatch is
# `fm-lock.sh --take`, permitted only when the holder is provably dead. Note what
# that does NOT claim: FM_HOME and FM_STATE_OVERRIDE scope the whole home, this
# check included, so pointing a verb at another state dir points the verb at
# another home - see docs/scripts.md for the one verb where those could be aimed
# apart, and what closes it.
fm_lock_require_helm() {
  local state=$1 label=$2 me rc
  me=$(fm_lock_harness_pid) || me=

  # ONE CLAIM PER INVOCATION. A batch spawn is a single writer action containing
  # several spawns: bin/fm-spawn.sh re-execs itself once per id=repo pair, so
  # without this the helm would be re-taken - mutex, write and all - once per
  # pair. If the recorded holder is ALREADY this session's harness then nobody
  # else can be steering, because becoming the holder means winning the CAS
  # against a live us, which fm_lock_cas refuses. So this is a pure read: no
  # mutex, no write, and the claim the parent made is the one the whole batch
  # runs under.
  if [ -n "$me" ] && [ "$(fm_lock_holder "$state" 2>/dev/null || true)" = "$me" ]; then
    return 0
  fi

  fm_lock_cas "$state" "$me"; rc=$?

  if [ "$rc" -eq 2 ]; then
    echo "refused: $label - could not serialise the helm claim (mutex $state/.lock.acquire busy); retry" >&2
    return 1
  fi

  if [ "$rc" -eq 1 ]; then
    {
      echo "refused: $label - another live session holds this home's helm (harness pid $FM_LOCK_HELD_BY)."
      echo "say to the captain: Another session is steering this home right now, so I'm reading rather than driving. Say the word if you want me to take the helm."
      echo "if that session has ended: bin/fm-lock.sh --take (permitted only when the holder is provably dead)"
      [ -n "$me" ] || echo "(this session's own harness could not be identified, so it cannot prove it is the holder)"
    } >&2
    return 1
  fi

  if [ -z "$me" ]; then
    echo "note: $label proceeding - nobody is steering this home, but this session's harness cannot be identified, so the helm was not claimed" >&2
  fi
  return 0
}
