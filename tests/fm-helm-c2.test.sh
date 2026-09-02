#!/usr/bin/env bash
# tests/fm-helm-c2.test.sh - gate-c2-helm-take-and-isolation.
#
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# Three properties that the writer-only seam (gate-c1) leans on.
#
# 1. --take IS THE ESCAPE HATCH, and it is permitted ONLY when the holder is
#    provably dead. A live holder is never evicted without the captain's word,
#    and the captain's word means ending that session - which is a human action,
#    so there is deliberately no force flag and no env bypass to test for.
# 2. ACQUIRE IS ATOMIC. Read the holder, judge it, write ours is a
#    compare-and-swap, and two sessions racing must not both conclude they hold
#    the helm. It is serialised by fm_lock_try_acquire (bin/fm-wake-lib.sh) held
#    across the whole critical section on state/.lock.acquire. That primitive is
#    already proven single-winner under 40-way concurrency by
#    tests/fm-watcher-lock.test.sh, on a free lock and on a stale one; what is
#    proven HERE is the other half - that fm-lock.sh actually holds it, and
#    writes nothing at all while it cannot.
# 3. SECONDMATES MUST NOT BREAK. Every secondmate home runs these same scripts
#    with its own FM_HOME, and fm-lock.sh is per-home. A secondmate must never be
#    refused because the MAIN firstmate holds the MAIN home's lock. This is the
#    most likely way the change breaks the fleet, so it is proven positively: the
#    secondmate drives a real mutation through while the main home stays held.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/helm-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helm-helpers.sh"

LOCKSH="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-c2)
REAL_LOCK_BEFORE=$(fm_helm_real_lock)
MUTEX_HOLDER=

cleanup() {
  [ -n "$MUTEX_HOLDER" ] && { kill "$MUTEX_HOLDER" 2>/dev/null || true; }
  fm_helm_kill_fakes
  fm_test_cleanup
}
trap cleanup EXIT


test_take_refuses_a_live_holder() {
  local dir state pid before out rc
  dir="$TMP_ROOT/take-live"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir")
  fm_helm_hold "$state" "$pid"
  before=$(shasum < "$state/.lock")

  rc=0; out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" --take 2>&1) || rc=$?
  expect_code 1 "$rc" "--take must refuse while the holder is alive"
  assert_contains "$out" "is a LIVE harness" "--take must say why it refused"
  assert_contains "$out" "never evicted without the captain's word" \
    "--take must name whose call an eviction is"
  assert_contains "$out" "reading rather than driving" \
    "--take must carry the captain-facing sentence the spec specifies"
  [ "$(shasum < "$state/.lock")" = "$before" ] \
    || fail "--take mutated the lock while refusing to take it"
  pass "--take refuses a live holder and leaves the lock byte-identical"
}


test_take_succeeds_only_when_the_holder_is_dead() {
  local dir state pid out rc me
  dir="$TMP_ROOT/take-dead"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir")
  fm_helm_hold "$state" "$pid"

  # Prove the holder is dead through the same reader the gate uses, so "dead" is
  # established rather than assumed.
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" status)
  assert_contains "$out" "lock: stale" "the holder must be provably dead before --take is allowed"

  rc=0; out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" --take 2>&1) || rc=$?
  expect_code 0 "$rc" "--take must succeed against a provably dead holder"
  assert_contains "$out" "from dead pid $pid" "--take must name the dead holder it took over from"
  me=$(cat "$state/.lock")
  [ "$me" != "$pid" ] || fail "--take reported success but left the dead holder recorded"
  out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" status)
  assert_contains "$out" "held by live harness pid $me" "after --take the helm must read as ours and live"
  pass "--take takes the helm from a provably dead holder and from nobody else"
}


test_bare_acquire_refuses_a_live_holder() {
  local dir state pid before rc out
  dir="$TMP_ROOT/acquire-live"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir")
  fm_helm_hold "$state" "$pid"
  before=$(shasum < "$state/.lock")

  rc=0; out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" 2>&1) || rc=$?
  expect_code 1 "$rc" "acquire must refuse while another live session holds the lock"
  assert_contains "$out" "operate read-only until resolved" "the acquire refusal contract changed"
  assert_contains "$out" "bin/fm-lock.sh --take" "the acquire refusal must point at the escape hatch"
  [ "$(shasum < "$state/.lock")" = "$before" ] || fail "a refused acquire overwrote the holder"
  pass "bare acquire refuses a live foreign holder without touching the lock"
}


# ATOMICITY, behaviourally. With the serialising mutex held by a live process,
# the compare-and-swap must not happen at all - not "happen and lose", not
# "happen anyway": nothing is written. Then, with the mutex released, the very
# same call succeeds, which is what makes the first half evidence rather than a
# coincidence of some unrelated failure.
test_acquire_is_serialised_by_the_mutex() {
  local dir state ready rc out before after
  dir="$TMP_ROOT/atomic"
  state="$dir/state"
  mkdir -p "$state"
  printf '99999999\n' > "$state/.lock"   # stale: acquire WOULD reclaim it
  before=$(shasum < "$state/.lock")
  ready="$dir/ready"

  # A real, live holder of state/.lock.acquire. It must stay alive: the primitive
  # reclaims a mutex whose owner is dead, and a dead holder would prove nothing.
  bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    : > "$3"
    while :; do sleep 1; done
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.lock.acquire" "$ready" >/dev/null 2>&1 </dev/null &
  MUTEX_HOLDER=$!
  local i=0
  while [ ! -f "$ready" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$ready" ] || fail "could not stand up a live holder of the acquire mutex"

  rc=0; out=$(FM_LOCK_ACQUIRE_TRIES=2 FM_STATE_OVERRIDE="$state" "$LOCKSH" 2>&1) || rc=$?
  expect_code 1 "$rc" "acquire must not proceed while the serialising mutex is held"
  assert_contains "$out" "could not serialise" "acquire must say the mutex was busy, not fail silently"
  after=$(shasum < "$state/.lock")
  [ "$before" = "$after" ] \
    || fail "the compare-and-swap ran outside the mutex - two racing sessions could both hold the helm"

  rc=0; out=$(FM_LOCK_ACQUIRE_TRIES=2 FM_STATE_OVERRIDE="$state" "$LOCKSH" --take 2>&1) || rc=$?
  expect_code 1 "$rc" "--take must be serialised by the same mutex"
  [ "$(shasum < "$state/.lock")" = "$before" ] || fail "--take swapped the lock outside the mutex"

  kill "$MUTEX_HOLDER" 2>/dev/null || true
  wait "$MUTEX_HOLDER" 2>/dev/null || true
  MUTEX_HOLDER=
  rm -rf "$state/.lock.acquire" "$state"/.lock.acquire.owner.* 2>/dev/null || true

  rc=0; out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" 2>&1) || rc=$?
  expect_code 0 "$rc" "control: with the mutex free the same acquire must succeed: $out"
  [ "$(shasum < "$state/.lock")" != "$before" ] \
    || fail "control: the acquire that was supposed to reclaim a stale lock changed nothing"
  pass "the compare-and-swap is indivisible: nothing is written while the mutex is held, and the same call then succeeds"
}


# A secondmate is a firstmate in its own home. It runs the same scripts with its
# own FM_HOME, so its helm is its own - and the main firstmate holding the MAIN
# home's lock must be invisible to it.
test_secondmate_home_has_its_own_helm() {
  local dir main sub pid rc out before after
  dir="$TMP_ROOT/secondmate"
  main="$dir/main"
  sub="$dir/sub"
  mkdir -p "$main/state" "$sub/state" "$sub/data"
  pid=$(fm_helm_live_harness "$dir")
  fm_helm_hold "$main/state" "$pid"

  # The main home refuses, as gate-c1 pins.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 1; }
    fm_lock_require_helm "$main/state" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "the main home must be refused while its own lock is held"

  # The secondmate home does not.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 1; }
    fm_lock_require_helm "$sub/state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a secondmate home must never be refused because the MAIN home is held"
  [ -z "$out" ] || fail "the secondmate home must pass silently, got: $out"

  # And positively: the secondmate actually DRIVES while the main home is held.
  fm_write_meta "$sub/state/s1.meta" \
    "window=fm-s1" "worktree=$sub" "project=$sub" \
    "harness=claude" "kind=scout" "mode=local-only" "yolo=off"
  before=$(shasum < "$main/state/.lock")
  rc=0; out=$(FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" "$ROOT/bin/fm-promote.sh" s1 2>&1) || rc=$?
  expect_code 0 "$rc" "a secondmate must be able to drive its own home while the main home is held: $out"
  assert_grep "kind=ship" "$sub/state/s1.meta" "the secondmate's drive verb did not actually run"
  after=$(shasum < "$main/state/.lock")
  [ "$before" = "$after" ] || fail "the secondmate's own work reached into the main home's lock"
  assert_absent "$sub/state/.lock" "driving a secondmate home must not invent a lock there"
  pass "a secondmate home keeps its own helm and drives freely while the main home is held"
}


test_real_lock_untouched() {
  [ "$(fm_helm_real_lock)" = "$REAL_LOCK_BEFORE" ] \
    || fail "this suite changed the captain's real lock at $FM_HELM_REAL_LOCK - it is scoped by FM_STATE_OVERRIDE and must never reach it"
  pass "the captain's real session lock is byte-identical before and after"
}


test_take_refuses_a_live_holder
test_take_succeeds_only_when_the_holder_is_dead
test_bare_acquire_refuses_a_live_holder
test_acquire_is_serialised_by_the_mutex
test_secondmate_home_has_its_own_helm
test_real_lock_untouched
