#!/usr/bin/env bash
# tests/fm-helm-c2.test.sh - gate-c2-helm-take-and-isolation.
#
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# What gate-c1 leans on.
#
# 1. EXCLUSIVITY IS PROVEN BY A RACE, not by a sequence. Two sessions checked one
#    after the other prove nothing about two sessions checked at once, and the
#    first cut of this seam was advisory - it answered "go ahead" for a free helm
#    without taking it, so the moment a holder died every observer read free and
#    every one of them drove. The test below launches N contenders with N distinct
#    harness identities at one free helm and requires exactly one winner.
# 2. --take IS THE ESCAPE HATCH, permitted ONLY when the holder is provably dead.
#    A live holder is never evicted without the captain's word, and that word
#    means ending that session - a human action - so there is deliberately no
#    force flag to test for.
# 3. NO REDIRECT IS A BYPASS. FM_HOME/FM_STATE_OVERRIDE scope the whole home, the
#    check included. fm-update is the one verb whose git target is not derived
#    from that home, so it is proven separately that an empty alternate state dir
#    cannot slip a self-update of a steered repo through.
# 4. SECONDMATES MUST NOT BREAK. Every secondmate home runs these same scripts
#    with its own FM_HOME. A secondmate must never be refused because the MAIN
#    firstmate holds the MAIN home's lock - the most likely way this change breaks
#    the fleet - so it is proven positively, by driving a real mutation through.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/helm-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helm-helpers.sh"

LOCKSH="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-c2)
WRAP="$TMP_ROOT/wrappers"
mkdir -p "$WRAP"
REAL_LOCK_BEFORE=$(fm_helm_real_lock)
MUTEX_HOLDER=

cleanup() {
  [ -n "$MUTEX_HOLDER" ] && { kill "$MUTEX_HOLDER" 2>/dev/null || true; }
  fm_helm_kill_fakes
  fm_test_cleanup
}
trap cleanup EXIT

# Run fm-lock.sh with a harness identity this test chose rather than the
# ancestry's, so these cases assert the same thing on CI, where nothing above the
# runner is an agent and an inherited identity would not resolve at all.
lock_verb() {  # <args...> -> sets RUN_OUT / RUN_CODE
  RUN_OUT=$(fm_helm_under_harness "$WRAP/lock" claude "$LOCKSH" "$@" 2>&1) && RUN_CODE=0 || RUN_CODE=$?
  return 0
}


# EXCLUSIVITY, concurrently. N contenders, N distinct real harness identities, one
# free helm, launched together. Exactly one may pass; the rest must see a live
# foreign holder.
#
# THE WINNER'S HOLD MUST OUTLIVE THE CONTENTION WINDOW. A contender that loses the
# serialising mutex backs off and retries for up to FM_LOCK_ACQUIRE_TRIES x 0.1s
# (3s by default), so if the winner's identity dies before that window closes, a
# late contender reclaims a genuinely dead holder and passes - which is CORRECT
# behaviour, not a bug, and would make this test fail for a reason that says
# nothing about exclusivity. Measured: with a 2s hold this reported three winners
# and every extra one had legitimately reclaimed a dead pid; with the hold below
# it reports one, repeatably. tests/fm-watcher-lock.test.sh documents the same
# hazard for the primitive underneath.
# shellcheck disable=SC2016  # the contender body is a literal script for the
# inner bash -c; its $1..$4 are that shell's positionals, not ours.
test_concurrent_claim_has_exactly_one_winner() {
  local dir state marker refused i pids pid wins losses
  dir="$TMP_ROOT/race"
  state="$dir/state"
  mkdir -p "$state" "$dir/h"
  marker="$dir/wins"
  refused="$dir/refused"
  : > "$marker"
  : > "$refused"
  # Each contender gets its OWN wrapper directory, so each resolves a different
  # pid as "this session's harness" - which is what makes them distinct sessions
  # rather than one session racing itself.
  i=1
  while [ "$i" -le 16 ]; do
    mkdir -p "$dir/h/$i"
    ln -s "$(command -v bash)" "$dir/h/$i/claude"
    "$dir/h/$i/claude" -c '"$@"; exit $?' _ bash -c '
      . "$1"
      if fm_lock_require_helm "$2" race 2>/dev/null; then
        printf "%s\n" "$(fm_lock_harness_pid)" >> "$3"
        sleep 8
      else
        printf "x\n" >> "$4"
      fi
    ' _ "$ROOT/bin/fm-lock-lib.sh" "$state" "$marker" "$refused" >/dev/null 2>&1 </dev/null &
    pids="${pids:-} $!"
    i=$((i + 1))
  done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done

  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  losses=$(awk 'NF { c++ } END { print c + 0 }' "$refused")
  [ "$wins" -eq 1 ] || fail "expected exactly one session to take the helm, got $wins (refused: $losses)"
  [ $((wins + losses)) -eq 16 ] || fail "expected all 16 contenders to reach a decision, got $wins + $losses"
  [ "$(cat "$state/.lock")" = "$(head -1 "$marker")" ] \
    || fail "the winner is not the recorded holder - the claim and the record disagree"
  pass "16 sessions racing one free helm: exactly one takes it, fifteen are refused"
}


test_take_refuses_a_live_holder() {
  local dir state pid before
  dir="$TMP_ROOT/take-live"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$state" "$pid"
  before=$(shasum < "$state/.lock")

  FM_STATE_OVERRIDE="$state" lock_verb --take
  expect_code 1 "$RUN_CODE" "--take must refuse while the holder is alive"
  assert_contains "$RUN_OUT" "is a LIVE harness" "--take must say why it refused"
  assert_contains "$RUN_OUT" "never evicted without the captain's word" \
    "--take must name whose call an eviction is"
  assert_contains "$RUN_OUT" "reading rather than driving" \
    "--take must carry the captain-facing sentence the spec specifies"
  [ "$(shasum < "$state/.lock")" = "$before" ] \
    || fail "--take mutated the lock while refusing to take it"
  pass "--take refuses a live holder and leaves the lock byte-identical"
}


# The same, with a `pi` holder: the harness name that must match as a whole word.
# Applied to a basename+argv composite it matched nothing, so a live pi session
# read as dead and --take EVICTED IT - the one thing the escape hatch must never
# do. This is that regression, at the verb.
test_take_refuses_a_live_pi_holder() {
  local dir state pid before
  dir="$TMP_ROOT/take-pi"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" pi)
  fm_helm_hold "$state" "$pid"
  before=$(shasum < "$state/.lock")

  FM_STATE_OVERRIDE="$state" lock_verb --take
  expect_code 1 "$RUN_CODE" "--take must refuse a live pi holder, not evict it"
  [ "$(shasum < "$state/.lock")" = "$before" ] || fail "--take evicted a LIVE pi holder"
  pass "--take refuses a live pi holder: the anchored harness name is matched, not silently missed"
}


test_take_succeeds_only_when_the_holder_is_dead() {
  local dir state pid out me
  dir="$TMP_ROOT/take-dead"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$state" "$pid"

  # Prove the holder is dead through the same reader the gate uses, so "dead" is
  # established rather than assumed.
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(FM_STATE_OVERRIDE="$state" "$LOCKSH" status)
  assert_contains "$out" "lock: stale" "the holder must be provably dead before --take is allowed"

  FM_STATE_OVERRIDE="$state" lock_verb --take
  expect_code 0 "$RUN_CODE" "--take must succeed against a provably dead holder: $RUN_OUT"
  assert_contains "$RUN_OUT" "from dead pid $pid" "--take must name the dead holder it took over from"
  me=$(cat "$state/.lock")
  [ "$me" != "$pid" ] || fail "--take reported success but left the dead holder recorded"
  pass "--take takes the helm from a provably dead holder and from nobody else"
}


# The bare acquire is recovery step 1 of every session, so finding another live
# steerer is the NORMAL outcome for the second instance, not a failure. It says so
# plainly and exits 0; gate-c1 asserts the same output carries no refusal string.
test_bare_acquire_reports_the_observer_plainly() {
  local dir state pid before
  dir="$TMP_ROOT/acquire-live"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$state" "$pid"
  before=$(shasum < "$state/.lock")

  FM_STATE_OVERRIDE="$state" lock_verb
  expect_code 0 "$RUN_CODE" "the bare acquire must not fail when another session is steering"
  assert_contains "$RUN_OUT" "observing, not steering" "the bare acquire must name the observer state"
  assert_contains "$RUN_OUT" "harness pid $pid" "the bare acquire must name who holds it"
  [ "$(shasum < "$state/.lock")" = "$before" ] || fail "a refused acquire overwrote the holder"
  pass "the bare acquire reports the observer state plainly and leaves the helm alone"
}


# ATOMICITY, behaviourally. With the serialising mutex held by a live process, the
# compare-and-swap must not happen at all - not "happen and lose", not "happen
# anyway": nothing is written. Then, with the mutex released, the very same call
# succeeds, which is what makes the first half evidence rather than a coincidence
# of some unrelated failure.
test_acquire_is_serialised_by_the_mutex() {
  local dir state ready before after i
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
  i=0
  while [ ! -f "$ready" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$ready" ] || fail "could not stand up a live holder of the acquire mutex"

  FM_LOCK_ACQUIRE_TRIES=2 FM_STATE_OVERRIDE="$state" lock_verb
  expect_code 1 "$RUN_CODE" "acquire must not proceed while the serialising mutex is held"
  assert_contains "$RUN_OUT" "could not serialise" "acquire must say the mutex was busy, not fail silently"
  after=$(shasum < "$state/.lock")
  [ "$before" = "$after" ] \
    || fail "the compare-and-swap ran outside the mutex - two racing sessions could both hold the helm"

  FM_LOCK_ACQUIRE_TRIES=2 FM_STATE_OVERRIDE="$state" lock_verb --take
  expect_code 1 "$RUN_CODE" "--take must be serialised by the same mutex"
  [ "$(shasum < "$state/.lock")" = "$before" ] || fail "--take swapped the lock outside the mutex"

  kill "$MUTEX_HOLDER" 2>/dev/null || true
  wait "$MUTEX_HOLDER" 2>/dev/null || true
  MUTEX_HOLDER=
  rm -rf "$state/.lock.acquire" "$state"/.lock.acquire.owner.* 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" lock_verb
  expect_code 0 "$RUN_CODE" "control: with the mutex free the same acquire must succeed: $RUN_OUT"
  [ "$(shasum < "$state/.lock")" != "$before" ] \
    || fail "control: the acquire that was supposed to reclaim a stale lock changed nothing"
  pass "the compare-and-swap is indivisible: nothing is written while the mutex is held, and the same call then succeeds"
}


# fm-watch-arm --restart KILLS this home's live watcher and starts a replacement.
# That is driving, not observing, so it gates - while plain arming, which is
# singleton-safe and no-ops against a healthy watcher, must not, because every
# session arms and a refusal there would be a boot-path refusal.
test_watch_arm_restart_gates_but_arming_does_not() {
  local dir state pid out code
  dir="$TMP_ROOT/watch-arm"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$state" "$pid"

  RUN_OUT=$(fm_helm_under_harness "$WRAP/wa" claude \
    env FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-watch-arm.sh" --restart 2>&1) && RUN_CODE=0 || RUN_CODE=$?
  expect_code 1 "$RUN_CODE" "--restart kills a live watcher and must gate on the helm"
  assert_contains "$RUN_OUT" "fm-watch-arm --restart" "the refusal must name the verb that was refused"
  assert_contains "$RUN_OUT" "reading rather than driving" "the refusal must carry the captain-facing sentence"

  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-watch-arm.sh" --status 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "watcher status is read-only and must never gate"
  assert_not_contains "$out" "refused:" "watcher status must not refuse"
  pass "--restart gates on the helm; reading watcher status does not"
}


# NO REDIRECT IS A BYPASS. FM_STATE_OVERRIDE scopes the whole home, so pointing a
# verb at another state dir points the verb at another home - except fm-update,
# whose git target comes from FM_ROOT. An empty alternate state dir must not slip
# a self-update of a repo whose own home is being steered.
test_an_alternate_state_dir_cannot_slip_fm_update_through() {
  local dir pid before after decoy
  dir="$TMP_ROOT/redirect"
  mkdir -p "$dir/root/state" "$dir/decoy"
  decoy="$dir/decoy"
  fm_git_identity
  fm_git_init_commit "$dir/root"
  # Pin the branch name. git's init.defaultBranch is `master` on a bare CI runner
  # and `main` on a machine that configured it, and fm-ff-lib resolves the default
  # from origin/HEAD and then checks the checked-out branch against it - so an
  # unpinned fixture fast-forwards on one platform and is skipped as "wrong
  # branch" on the other, which is what made this control pass locally and fail on
  # ubuntu.
  git -C "$dir/root" branch -q -M main
  fm_git_add_origin "$dir/root" "$dir/root-origin"
  git -C "$dir/root" push -q origin HEAD:main 2>/dev/null || git -C "$dir/root" push -q origin HEAD
  git -C "$dir/root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
  printf 'state/\n' > "$dir/root/.gitignore"
  git -C "$dir/root" add .gitignore
  git -C "$dir/root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm ignore
  printf 'ahead\n' > "$dir/root/ahead.txt"
  git -C "$dir/root" add ahead.txt
  git -C "$dir/root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm ahead
  git -C "$dir/root" push -q origin HEAD:main
  git -C "$dir/root" reset -q --hard HEAD~1

  # The repo's OWN home is steered; the check is pointed at an empty decoy.
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$dir/root/state" "$pid"
  before=$(git -C "$dir/root" rev-parse HEAD)

  RUN_OUT=$(fm_helm_under_harness "$WRAP/redir" claude \
    env FM_HOME="$dir" FM_STATE_OVERRIDE="$decoy" FM_ROOT_OVERRIDE="$dir/root" \
    "$ROOT/bin/fm-update.sh" 2>&1) && RUN_CODE=0 || RUN_CODE=$?
  after=$(git -C "$dir/root" rev-parse HEAD)
  [ "$before" = "$after" ] \
    || fail "an empty alternate state dir slipped a self-update of a steered repo through"
  expect_code 1 "$RUN_CODE" "fm-update must refuse when the repo's own home is steered: $RUN_OUT"
  assert_contains "$RUN_OUT" "repo at $dir/root" "the refusal must name the repo whose home is held"
  pass "pointing the check at another state dir cannot slip fm-update past a steered repo"
}


# A secondmate is a firstmate in its own home. It runs the same scripts with its
# own FM_HOME, so its helm is its own - and the main firstmate holding the MAIN
# home's lock must be invisible to it.
# shellcheck disable=SC2031  # the subshells only OVERRIDE fm_lock_harness_pid
test_secondmate_home_has_its_own_helm() {
  local dir main sub pid rc out before after
  dir="$TMP_ROOT/secondmate"
  main="$dir/main"
  sub="$dir/sub"
  mkdir -p "$main/state" "$sub/state" "$sub/data"
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$main/state" "$pid"

  # The main home refuses, as gate-c1 pins.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 1; }
    fm_lock_require_helm "$main/state" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "the main home must be refused while its own lock is held"

  # The secondmate home does not.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 4711; }
    fm_lock_require_helm "$sub/state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a secondmate home must never be refused because the MAIN home is held"
  [ -z "$out" ] || fail "the secondmate home must pass silently, got: $out"

  # And positively: the secondmate actually DRIVES while the main home is held.
  fm_write_meta "$sub/state/s1.meta" \
    "window=fm-s1" "worktree=$sub" "project=$sub" \
    "harness=claude" "kind=scout" "mode=local-only" "yolo=off"
  before=$(shasum < "$main/state/.lock")
  RUN_OUT=$(fm_helm_under_harness "$WRAP/sub" claude \
    env FM_HOME="$sub" FM_ROOT_OVERRIDE="$sub" "$ROOT/bin/fm-promote.sh" s1 2>&1) && RUN_CODE=0 || RUN_CODE=$?
  expect_code 0 "$RUN_CODE" "a secondmate must be able to drive its own home while the main home is held: $RUN_OUT"
  assert_grep "kind=ship" "$sub/state/s1.meta" "the secondmate's drive verb did not actually run"
  after=$(shasum < "$main/state/.lock")
  [ "$before" = "$after" ] || fail "the secondmate's own work reached into the main home's lock"
  assert_present "$sub/state/.lock" "the secondmate that drove must hold ITS OWN helm"
  [ "$(cat "$sub/state/.lock")" != "$pid" ] || fail "the secondmate recorded the MAIN home's holder as its own"
  pass "a secondmate home keeps its own helm and drives freely while the main home is held"
}


test_real_lock_untouched() {
  [ "$(fm_helm_real_lock)" = "$REAL_LOCK_BEFORE" ] \
    || fail "this suite changed the captain's real lock at $FM_HELM_REAL_LOCK - it is scoped by FM_STATE_OVERRIDE and must never reach it"
  pass "the captain's real session lock is byte-identical before and after"
}


test_concurrent_claim_has_exactly_one_winner
test_take_refuses_a_live_holder
test_take_refuses_a_live_pi_holder
test_take_succeeds_only_when_the_holder_is_dead
test_bare_acquire_reports_the_observer_plainly
test_acquire_is_serialised_by_the_mutex
test_watch_arm_restart_gates_but_arming_does_not
test_an_alternate_state_dir_cannot_slip_fm_update_through
test_secondmate_home_has_its_own_helm
test_real_lock_untouched
