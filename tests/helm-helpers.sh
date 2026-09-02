#!/usr/bin/env bash
# tests/helm-helpers.sh - fixtures for the helm (per-home session lock) gates.
#
# Source AFTER tests/lib.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/helm-helpers.sh"
#
# Two fixtures carry these suites, and each exists because the obvious version of
# it was wrong.
#
# A VERIFIED LIVE HOLDER. Every refusal asserted here is conditional on the lock
# naming a live harness, so a silently-stale fixture would make all of them pass
# for the wrong reason - the writer would be waved through and the test would
# still be green, because "was not refused" is not what it asserts. fm_helm_hold
# therefore reads the fixture back through fm-lock.sh status and fails the suite
# unless it says "held by live harness pid".
#
# A CHOSEN HARNESS IDENTITY. The seam asks who THIS session's harness is by
# walking the process ancestry, so a suite that just runs a drive verb asserts
# whatever ancestry it happens to have: inside an agent it resolves one, and in
# CI - ubuntu-latest running tests/run-all.sh with no agent anywhere above it -
# it resolves nothing and the seam fails open, so every refusal case silently
# stops testing a refusal. fm_helm_under_harness gives the verb a real parent
# process the seam recognises, so these gates assert the same thing on a laptop
# and on a runner.

if [ -n "${FM_HELM_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_HELM_HELPERS_SOURCED=1

# Fixture pids go through a FILE, not a variable. fm_helm_live_harness is called
# as `pid=$(fm_helm_live_harness ...)`, and a command substitution is a SUBSHELL:
# a variable appended there dies with it, so the parent's kill list stayed empty
# and every fixture outlived its suite. That is not theoretical - it left 58
# infinite-loop processes running on the captain's machine. tests/lib.sh solved
# the identical problem for temp dirs the identical way.
FM_HELM_PID_REGISTRY="${TMPDIR:-/tmp}/fm-helm-pids.$$"

# fm_helm_live_harness <dir> [name]
# Start a REAL process that fm-lock.sh's harness detection accepts, and echo its
# pid. It is a SYMLINK to bash, so `ps -o comm=` reports the link's own basename:
# that is what lets a fixture named `pi` be recognised through the anchored half
# of the harness pattern, which is exactly the case that used to read as dead. A
# copy of a system binary is not usable - on macOS a copied signed binary is
# killed on exec, so the "live" holder would be dead before the first assertion -
# and a `#!` script is not either, because its comm is the interpreter.
fm_helm_live_harness() {
  local dir=$1 name=${2:-codex} link pid i=0
  mkdir -p "$dir"
  link="$dir/$name"
  [ -e "$link" ] || ln -s "$(command -v bash)" "$link"
  # Detached from the suite's stdout and stdin on purpose: a background fixture
  # that inherits the pipe holds it open after the suite exits, and the runner
  # then waits forever on a process that is only a prop.
  "$link" -c 'while :; do sleep 1; done' >/dev/null 2>&1 </dev/null &
  pid=$!
  while [ "$i" -lt 60 ]; do
    ps -o comm= -p "$pid" 2>/dev/null | grep -q "$name" && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 60 ] || fail "fake harness $name never became visible to ps"
  printf '%s\n' "$pid" >> "$FM_HELM_PID_REGISTRY"
  printf '%s\n' "$pid"
}

fm_helm_kill_fakes() {
  local p
  if [ -f "$FM_HELM_PID_REGISTRY" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      kill "$p" 2>/dev/null || true
    done < "$FM_HELM_PID_REGISTRY"
    rm -f "$FM_HELM_PID_REGISTRY"
  fi
  return 0
}

# fm_helm_under_harness <dir> <name> <cmd> [args...]
# Run <cmd> with a live parent process the seam resolves as this session's
# harness, so `me` is chosen by the test rather than inherited from whatever ran
# the suite. The parent is a bash symlinked to <name>; `"$@"; exit $?` is two
# commands on purpose, because bash -c with a single simple command execs it and
# the wrapper would vanish into its own child, taking the identity with it.
# Echoes the wrapper's pid on fd 3 is not portable enough to bother with: use
# fm_helm_harness_id when the caller needs to know who it was.
fm_helm_under_harness() {
  local dir=$1 name=$2 link
  shift 2
  mkdir -p "$dir"
  link="$dir/$name"
  [ -e "$link" ] || ln -s "$(command -v bash)" "$link"
  "$link" -c '"$@"; exit $?' _ "$@"
}

# fm_helm_harness_id <dir> <name>: the pid fm_lock_harness_pid would return for a
# command run through fm_helm_under_harness with these arguments. Used to prove
# the fixture chose a DIFFERENT identity from the holder, so a refusal is a real
# refusal and not two names for one session.
# shellcheck disable=SC2016  # $1 is the inner bash -c's own positional, not ours
fm_helm_harness_id() {
  fm_helm_under_harness "$1" "$2" bash -c '. "$1"; fm_lock_harness_pid' _ "$ROOT/bin/fm-lock-lib.sh"
}

# fm_helm_hold <state-dir> <pid>: record <pid> as this home's holder, then PROVE
# the fixture is what the suite thinks it is before anything is asserted on it.
fm_helm_hold() {
  local state=$1 pid=$2 out
  mkdir -p "$state"
  printf '%s\n' "$pid" > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: held by live harness pid $pid" ] \
    || fail "helm fixture is not a verified live holder (fm-lock.sh status said: $out)"
}

# fm_helm_snapshot <dir>: a shape-and-content fingerprint of a whole tree - every
# path, every file's hash, every symlink target. Two snapshots comparing equal is
# the behavioural proof that a refused writer mutated NOTHING: no state file
# written, and, because a git repo's refs and objects are files, no fetch and no
# fast-forward either. Grepping for a refusal message would pass while the writes
# still happened.
fm_helm_snapshot() {
  ( cd "$1" 2>/dev/null || return 1
    find . | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf '%s L %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then printf '%s D\n' "$p"
      else printf '%s F %s\n' "$p" "$(shasum < "$p" | cut -d' ' -f1)"
      fi
    done )
}

# The captain's REAL home. These suites are scoped by FM_STATE_OVERRIDE, which is
# the only reason they are safe to run at all; fm_helm_real_lock is how that
# claim is checked rather than assumed. A test that quietly took the real lock
# would take the captain's fleet down.
FM_HELM_REAL_LOCK="${HOME:-/nonexistent}/firstmate/state/.lock"

fm_helm_real_lock() {
  if [ -e "$FM_HELM_REAL_LOCK" ]; then
    shasum < "$FM_HELM_REAL_LOCK"
  else
    echo ABSENT
  fi
}
