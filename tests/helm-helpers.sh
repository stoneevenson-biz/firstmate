#!/usr/bin/env bash
# tests/helm-helpers.sh - fixtures for the helm (per-home session lock) gates.
#
# Source AFTER tests/lib.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/helm-helpers.sh"
#
# The one fixture that matters here is a VERIFIED LIVE HOLDER. Every refusal
# these suites assert is conditional on the lock naming a live harness, so a
# fixture that is silently stale would make every one of them pass for the wrong
# reason - the writer would be allowed through and the test would still be green,
# because "was not refused" is not what it asserts. fm_helm_hold therefore reads
# the fixture back through fm-lock.sh status and fails the suite unless it says
# "held by live harness pid".
#
# These helpers assert nothing else; the gates own their own assertions.

if [ -n "${FM_HELM_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_HELM_HELPERS_SOURCED=1

FM_HELM_FAKE_PIDS=

# fm_helm_live_harness <dir> [name]
# Start a REAL process that fm-lock.sh's harness detection accepts, and echo its
# pid. A copy of a system binary is NOT usable here: on macOS a copied signed
# binary is killed on exec, so the "live" holder is dead before the first
# assertion - which is exactly the silently-stale fixture this file exists to
# prevent. A shell script named for a verified harness is matched through the
# `ps -o args=` half of fm_lock_holder_alive, and stays alive.
fm_helm_live_harness() {
  local dir=$1 name=${2:-codex} script pid i=0
  mkdir -p "$dir"
  script="$dir/$name"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$script"
  # Detached from the suite's stdout and stdin on purpose: a background fixture
  # that inherits the pipe holds it open after the suite exits, and the runner
  # then waits forever on a process that is only a prop.
  "$script" >/dev/null 2>&1 </dev/null &
  pid=$!
  while [ "$i" -lt 60 ]; do
    ps -o args= -p "$pid" 2>/dev/null | grep -q "$name" && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 60 ] || fail "fake harness $name never became visible to ps"
  FM_HELM_FAKE_PIDS="$FM_HELM_FAKE_PIDS $pid"
  printf '%s\n' "$pid"
}

fm_helm_kill_fakes() {
  local p
  for p in $FM_HELM_FAKE_PIDS; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  FM_HELM_FAKE_PIDS=
  return 0
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
