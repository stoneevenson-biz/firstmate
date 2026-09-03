#!/usr/bin/env bash
# GATE t4-restart-scope - `--restart` stops THIS home's watcher and nothing else.
#
# THE DEFECT THIS FREEZES. `bin/fm-watch-arm.sh --restart` is documented to stop
# only this home's watcher, via the pid recorded in THIS home's
# state/.watch.lock. The record it depends on was written best-effort with a
# trailing `|| true` - and on the captain's home on 2026-09-02 the lock files
# were observed ZERO-LENGTH while a watcher ran. With no record, the restart can
# prove nothing about the live pid it finds: it declines to signal it (right),
# then forks a replacement that cannot take the still-held lock either, and the
# home is left with a watcher it can neither use nor replace. The documented
# contract and the code had drifted apart with no gate between them.
#
# WHY IT MATTERS BEYOND ONE HOME. The alternative every operator reaches for is
# `pkill -f bin/fm-watch.sh`, and that pattern matches EVERY firstmate home on
# the machine - every secondmate runs the same script. So the property under
# test is not "restart works", it is "restart is scoped", and it is proven
# against a real second home running a real second watcher rather than asserted.
#
# WHAT IS GATED:
#   * the record is actually written: a running watcher's lock names a live pid
#     and carries a complete identity - the literal thing that was empty;
#   * a restart in home A replaces A's watcher and leaves home B's watcher
#     running with its lock byte-for-byte untouched;
#   * a live pid the record cannot prove is ours is REFUSED, signalling nothing,
#     rather than becoming a kill of something unidentified;
#   * the classifier answers all five cases, so both callers read one rule.
#
# Mutation (LEDGER_MUTATE=1): rewrite home A's own lock to name home B as its
# home just before the restart. A correct restart then refuses - correctly, it
# can no longer prove the pid is A's - and A is not restarted, which fails the
# assertion. That proves this gate is keyed on the restart actually happening
# and not merely on B surviving, which it would do even if nothing ran at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_LIB_READONLY=1 . "$ROOT/bin/fm-wake-lib.sh"

# Same shape as tests/herdr-helpers.sh's, defined here because this suite has no
# business pulling in the herdr fakes just to compare two strings.
assert_eq() {
  if [ "$1" = "$2" ]; then return 0; fi
  fail "$3 (expected '$2', got '$1')"
}

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-t4-restart)

WATCH_ENV=(FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_MAX=999999)
STARTED_PIDS=""

cleanup() {
  local p
  for p in $STARTED_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup EXIT

# start_watcher <home> -> the watcher pid recorded in that home's lock.
#
# READINESS IS THE BEACON, not the lock record. The watcher touches
# .last-watcher-beat at the top of its first cycle, which is after it has
# claimed the lock and written its identity - so waiting on the beacon means the
# startup is complete without the wait itself asserting anything about the
# record this gate is here to check.
start_watcher() {
  local home=$1 pid i lock_pid
  mkdir -p "$home/state"
  env "${WATCH_ENV[@]}" FM_HOME="$home" "$WATCH" > "$home/watch.out" 2>&1 &
  pid=$!
  STARTED_PIDS="$STARTED_PIDS $pid"
  i=0
  while [ "$i" -lt 150 ]; do
    lock_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null \
       && [ -e "$home/state/.last-watcher-beat" ]; then
      printf '%s\n' "$lock_pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "no watcher came up in $home: $(cat "$home/watch.out" 2>/dev/null)"
}

lock_snapshot() {
  local home=$1 f
  for f in pid fm-home watcher-path pid-identity; do
    printf '%s=%s\n' "$f" "$(cat "$home/state/.watch.lock/$f" 2>/dev/null || echo MISSING)"
  done
}

# --- the record itself: what was observed empty ------------------------------

test_a_running_watcher_records_a_complete_identity() {
  local home pid f value
  home="$TMP_ROOT/record"
  pid=$(start_watcher "$home")
  for f in pid fm-home watcher-path pid-identity; do
    value=$(cat "$home/state/.watch.lock/$f" 2>/dev/null || true)
    [ -n "$value" ] || fail "a running watcher left $f empty in its lock; --restart can prove nothing about it"
  done
  assert_eq "$(cat "$home/state/.watch.lock/pid")" "$pid" "the lock does not name the live watcher"
  assert_eq "$(cat "$home/state/.watch.lock/fm-home")" "$home" "the lock does not name its own home"
  pass "t4: a running watcher's lock names a live pid with a complete identity"
}

# --- the scope: two real homes, two real watchers ----------------------------

test_restart_stops_only_this_homes_watcher() {
  local a b a_pid b_pid b_before b_after arm_pid i a_new
  a="$TMP_ROOT/home-a"; b="$TMP_ROOT/home-b"
  a_pid=$(start_watcher "$a")
  b_pid=$(start_watcher "$b")
  b_before=$(lock_snapshot "$b")

  [ "${LEDGER_MUTATE:-}" = 1 ] && printf '%s\n' "$b" > "$a/state/.watch.lock/fm-home"

  env "${WATCH_ENV[@]}" FM_HOME="$a" "$WATCH_ARM" --restart > "$a/restart.out" 2>&1 &
  arm_pid=$!
  STARTED_PIDS="$STARTED_PIDS $arm_pid"
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$a/restart.out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done

  a_new=$(cat "$a/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -z "$a_new" ] || [ "$a_new" = "$a_pid" ] || ! kill -0 "$a_new" 2>/dev/null; then
    fail "home A's watcher was not replaced by a fresh live one (lock names '${a_new:-none}', was $a_pid): $(cat "$a/restart.out")"
  fi
  STARTED_PIDS="$STARTED_PIDS $a_new"
  kill -0 "$a_pid" 2>/dev/null && fail "home A's old watcher $a_pid was left running alongside its replacement"

  # The whole point: the sibling home is untouched.
  kill -0 "$b_pid" 2>/dev/null || fail "home B's watcher was killed by a restart in home A; --restart became a broad kill"
  b_after=$(lock_snapshot "$b")
  assert_eq "$b_after" "$b_before" "home B's watcher lock was modified by a restart in home A"
  pass "t4: --restart replaces this home's watcher and leaves a second home's untouched"
}

# --- the refusal: a live pid nothing can prove is ours ------------------------

test_restart_refuses_an_unidentified_live_lock() {
  local home sleeper out rc=0
  home="$TMP_ROOT/unidentified"
  mkdir -p "$home/state"
  sleep 300 >/dev/null 2>&1 &
  sleeper=$!
  STARTED_PIDS="$STARTED_PIDS $sleeper"
  # The observed shape: a live pid behind an empty record.
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$sleeper" > "$home/state/.watch.lock/pid"
  : > "$home/state/.watch.lock/fm-home"
  : > "$home/state/.watch.lock/watcher-path"
  : > "$home/state/.watch.lock/pid-identity"

  set +e
  out=$(env "${WATCH_ENV[@]}" FM_ARM_CONFIRM_TIMEOUT=2 FM_HOME="$home" "$WATCH_ARM" --restart 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "a restart over an unprovable live lock reported success"
  assert_contains "$out" "REFUSED" "the refusal is not reported as one"
  assert_contains "$out" "$sleeper" "the refusal does not name the process it declined to signal"
  kill -0 "$sleeper" 2>/dev/null || fail "the restart signalled a process it could not prove was its watcher"
  assert_eq "$(cat "$home/state/.watch.lock/pid")" "$sleeper" \
    "the restart cleared a lock held by a live pid it could not identify"
  pass "t4: a live pid with no provable identity is refused, not killed"
}

# --- the rule both callers read ----------------------------------------------

test_the_classifier_answers_every_case() {
  local home sleeper dead watch_path
  home="$TMP_ROOT/classify"
  mkdir -p "$home/state"
  watch_path="$ROOT/bin/fm-watch.sh"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" none \
    "an absent lock is not reported as none"

  sleep 300 >/dev/null 2>&1 &
  sleeper=$!
  STARTED_PIDS="$STARTED_PIDS $sleeper"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$sleeper" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$watch_path" > "$home/state/.watch.lock/watcher-path"
  fm_pid_identity "$sleeper" > "$home/state/.watch.lock/pid-identity"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" ours-live \
    "a live pid whose whole record matches is not reported as ours"

  printf 'a different process entirely\n' > "$home/state/.watch.lock/pid-identity"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" stale \
    "a reused pid the record contradicts is not reported as stale"

  fm_pid_identity "$sleeper" > "$home/state/.watch.lock/pid-identity"
  printf '%s\n' "$home/somewhere-else" > "$home/state/.watch.lock/fm-home"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" foreign \
    "a live watcher belonging to another home is not reported as foreign"

  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  : > "$home/state/.watch.lock/pid-identity"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" unidentified \
    "a live pid behind an incomplete record is not reported as unidentified"

  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf '%s\n' "$dead" > "$home/state/.watch.lock/pid"
  assert_eq "$(fm_watch_lock_classify "$home/state/.watch.lock" "$home" "$watch_path")" stale \
    "a dead pid is not reported as stale"
  pass "t4: the lock classifier answers all five cases, so both callers read one rule"
}

test_a_running_watcher_records_a_complete_identity
test_restart_stops_only_this_homes_watcher
test_restart_refuses_an_unidentified_live_lock
test_the_classifier_answers_every_case
