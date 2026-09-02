#!/usr/bin/env bash
# tests/fm-helm-c1.test.sh - gate-c1-helm-writer-only.
#
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
#
# THE LOCK GUARDS MUTATION, NOT ACTIVATION. A second session on the same home is
# an observer, not an error: it boots fully, reads anything, reasons and drafts,
# and is stopped only when it asks to spawn / steer / tear down / merge - at that
# verb, at that moment. This gate pins both halves, and the second half is the one
# firstmate got backwards twice: NO BOOT PATH MAY EMIT A REFUSAL. That includes
# the bare `bin/fm-lock.sh` acquire, which is what AGENTS.md section 5 actually
# names as recovery step 1 - asserting on `status` instead would test a command
# the doctrine never runs at startup.
#
# THE REFUSAL ASSERTIONS ARE BEHAVIOURAL. Each blocked writer is checked against a
# whole-tree fingerprint taken before it ran: no state file written, and - because
# a git repo's refs and objects are files inside the fingerprinted tree - no fetch
# and no fast-forward. Greping for the refusal message alone would pass while
# every write still happened. Two positive controls prove the fixtures are not
# vacuous: with the helm free, the same fm-promote call rewrites the meta and the
# same fm-update call fast-forwards the repo it refused to touch.
#
# THE HARNESS IDENTITY IS CHOSEN, NOT INHERITED. Every drive verb runs under a
# fixture parent the seam resolves as this session's harness, so these cases
# assert a refusal on a laptop inside an agent AND on CI's ubuntu runner, where
# there is no agent in the ancestry at all and an inherited identity would make
# the seam fail open and every refusal case quietly stop testing anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/helm-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helm-helpers.sh"
# shellcheck source=tests/fm-boot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-helm-c1)
# Kept OUT of any fingerprinted tree: the wrappers are the test's apparatus, not
# something the code under test may or may not write.
WRAP="$TMP_ROOT/wrappers"
mkdir -p "$WRAP"
REAL_LOCK_BEFORE=$(fm_helm_real_lock)

cleanup() {
  fm_helm_kill_fakes
  fm_test_cleanup
}
trap cleanup EXIT

# Every string a refusal can reach a reader by. The boot assertions below are
# "none of these appears", so this list is the definition of "reads as an error".
REFUSAL_MARKERS='refused:
reading rather than driving
holds this home.s helm
take the helm
operate read-only until resolved'

assert_no_refusal() {  # <label> <output>
  local marker
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    printf '%s' "$2" | grep -qE "$marker" \
      && fail "$1 emitted a helm refusal at boot: matched '$marker'"$'\n'"--- output ---"$'\n'"$2"
  done <<EOF
$REFUSAL_MARKERS
EOF
  return 0
}

# A home with the shape the drive verbs read: a scout meta they can act on, a
# project clone, and a git repo standing in for FM_ROOT with an origin that is
# one commit ahead - so a real fm-update would demonstrably fetch and advance.
make_home() {
  local dir=$1 home fakebin
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  fm_git_identity
  fm_git_init_commit "$home/projects/proj"
  git -C "$home/projects/proj" branch -q "fm/t1" 2>/dev/null || true
  fm_write_meta "$home/state/t1.meta" \
    "window=fm-t1" \
    "worktree=$home/projects/proj" \
    "project=$home/projects/proj" \
    "harness=claude" \
    "kind=scout" \
    "mode=local-only" \
    "yolo=off"
  printf '# backlog\n' > "$home/data/backlog.md"
  printf '# projects\n\n- proj [local-only] - fixture (added 2026-09-01)\n' > "$home/data/projects.md"

  # FM_ROOT stand-in: on its default branch (so the tangle guard stays inert)
  # with origin one commit ahead, which is what makes "no fast-forward" provable.
  fm_git_init_commit "$dir/root"
  fm_git_add_origin "$dir/root" "$dir/root-origin"
  git -C "$dir/root" push -q origin HEAD:main 2>/dev/null || git -C "$dir/root" push -q origin HEAD
  git -C "$dir/root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null || true
  printf 'ahead\n' > "$dir/root/ahead.txt"
  git -C "$dir/root" add ahead.txt
  git -C "$dir/root" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm ahead
  git -C "$dir/root" push -q origin HEAD:main
  git -C "$dir/root" reset -q --hard HEAD~1

  # treehouse REFUSES here rather than no-opping. fm-spawn leases a real slot
  # from the captain's live pool whatever FM_HOME says, so if the helm gate ever
  # regressed, a stub that quietly succeeded would leak a durable lease into his
  # fleet. Refusing means a regression fails this test instead.
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse must never be reached by this suite" >&2
exit 97
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$home"
}

# Run a drive verb with a harness identity this test chose, not the ancestry's.
# shellcheck disable=SC2030,SC2031  # the exports are deliberately scoped to the
# command-substitution subshell; nothing outside it reads them back.
run_verb() {  # <dir> <home> <args...> -> sets RUN_OUT / RUN_CODE
  local dir=$1 home=$2
  shift 2
  RUN_OUT=$(
    export PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$dir/root"
    fm_helm_under_harness "$WRAP/drive" claude "$@" 2>&1
  ) && RUN_CODE=0 || RUN_CODE=$?
  return 0
}

VERB_ROWS='fm-spawn^SPAWN
fm-send^SEND
fm-teardown^TEARDOWN
fm-merge-local^MERGE
fm-pr-check^PRCHECK
fm-promote^PROMOTE
fm-update^UPDATE'

verb_args() {  # <key> <home> -> the argv for that verb
  case "$1" in
    SPAWN)    printf '%s\n' "$ROOT/bin/fm-spawn.sh" t1 "$2/projects/proj" ;;
    SEND)     printf '%s\n' "$ROOT/bin/fm-send.sh" fm-t1 hello ;;
    TEARDOWN) printf '%s\n' "$ROOT/bin/fm-teardown.sh" t1 ;;
    MERGE)    printf '%s\n' "$ROOT/bin/fm-merge-local.sh" t1 ;;
    PRCHECK)  printf '%s\n' "$ROOT/bin/fm-pr-check.sh" t1 https://example.invalid/pr/1 ;;
    PROMOTE)  printf '%s\n' "$ROOT/bin/fm-promote.sh" t1 ;;
    UPDATE)   printf '%s\n' "$ROOT/bin/fm-update.sh" ;;
  esac
}


# <case-dir> <holder-harness-name>: every drive verb refuses, and writes nothing.
assert_all_verbs_refuse_under() {
  local dir=$1 hname=$2 home pid before after label key args mine
  mkdir -p "$dir"
  home=$(make_home "$dir")
  pid=$(fm_helm_live_harness "$dir/fixture" "$hname")
  fm_helm_hold "$home/state" "$pid"

  # A refusal only means something if the refused session is a DIFFERENT one.
  mine=$(fm_helm_harness_id "$WRAP/drive" claude)
  [ -n "$mine" ] || fail "$hname: the fixture harness identity did not resolve"
  [ "$mine" != "$pid" ] || fail "$hname: the fixture identity collided with the holder"

  before=$(fm_helm_snapshot "$dir")
  while IFS='^' read -r label key; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2046  # verb_args deliberately word-splits into argv
    run_verb "$dir" "$home" $(verb_args "$key" "$home")
    [ "$RUN_CODE" -ne 0 ] || fail "$label was allowed through while a live $hname session held the helm"
    assert_contains "$RUN_OUT" "another live session holds this home's helm (harness pid $pid)" \
      "$label did not refuse with the writer-only seam's message (holder harness: $hname)"
    assert_contains "$RUN_OUT" "Another session is steering this home right now, so I'm reading rather than driving." \
      "$label did not carry the captain-facing sentence the spec specifies"
    assert_contains "$RUN_OUT" "bin/fm-lock.sh --take" "$label did not name the escape hatch"
  done <<ROWS
$VERB_ROWS
ROWS

  after=$(fm_helm_snapshot "$dir")
  if [ "$before" != "$after" ]; then
    fail "a refused writer mutated the tree (holder harness: $hname)"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  fi
}


test_drive_verbs_refuse_and_mutate_nothing() {
  assert_all_verbs_refuse_under "$TMP_ROOT/refuse-codex" codex
  pass "every drive verb refuses under a live foreign helm and writes nothing at all"
}


# THE REGRESSION. `pi` is a declared harness and a verified adapter, and it is the
# one name in the pattern that must match as a whole word. Applying that pattern
# to a `basename + argv` composite made it match NOTHING, so a live pi holder read
# as dead: the seam waved observers through and --take evicted a live session. The
# holder here is a real process whose comm is literally `pi`.
test_a_live_pi_holder_is_not_read_as_dead() {
  local dir pid
  dir="$TMP_ROOT/pi"
  mkdir -p "$dir/fixture"
  pid=$(fm_helm_live_harness "$dir/fixture" pi)
  assert_contains "$(FM_STATE_OVERRIDE="$dir/probe" bash -c '
    . "$1"; if fm_lock_pid_is_harness "$2"; then echo LIVE; else echo DEAD; fi' _ "$ROOT/bin/fm-lock-lib.sh" "$pid")" \
    LIVE "a live pi process must be recognised as a harness"
  assert_all_verbs_refuse_under "$TMP_ROOT/refuse-pi" pi
  pass "a live pi holder is seen as live: every drive verb still refuses"
}


# The refusal assertions above are only worth something if these same calls WOULD
# have mutated with the helm free. Two controls, one per kind of mutation the
# fingerprint is watching: a state write, and a git fast-forward. And a third
# property the seam owes: proceeding on a free helm means it TOOK the helm.
test_positive_controls_and_the_claim() {
  local dir home before_head after_head mine
  dir="$TMP_ROOT/control"
  mkdir -p "$dir"
  home=$(make_home "$dir")
  rm -f "$home/state/.lock"
  mine=$(fm_helm_harness_id "$WRAP/drive" claude)

  run_verb "$dir" "$home" "$ROOT/bin/fm-promote.sh" t1
  [ "$RUN_CODE" -eq 0 ] || fail "control: fm-promote failed with a free helm: $RUN_OUT"
  assert_grep "kind=ship" "$home/state/t1.meta" "control: fm-promote did not rewrite the meta with a free helm"
  assert_present "$home/state/.lock" \
    "a drive verb that proceeded on a free helm must have CLAIMED it - an advisory check that never claims is not a lock"
  [ "$(cat "$home/state/.lock")" != "$mine" ] \
    || fail "internal: the wrapper pid should differ per invocation; got the same id twice"

  before_head=$(git -C "$dir/root" rev-parse HEAD)
  run_verb "$dir" "$home" "$ROOT/bin/fm-update.sh"
  [ "$RUN_CODE" -eq 0 ] || fail "control: fm-update failed with a free helm: $RUN_OUT"
  after_head=$(git -C "$dir/root" rev-parse HEAD)
  [ "$before_head" != "$after_head" ] \
    || fail "control: fm-update did not fast-forward with a free helm, so the refusal case proved nothing"
  pass "with the helm free the same calls DO mutate, and a verb that proceeds has claimed the helm"
}


# shellcheck disable=SC2030,SC2031  # per-invocation PATH scoping, by design
test_no_boot_path_refuses() {
  local dir home pid fakebin out code
  dir="$TMP_ROOT/boot"
  mkdir -p "$dir"
  home="$dir/home"
  fm_boot_make_home "$home" 2
  fm_boot_make_fleet "$dir/fleet" 2
  pid=$(fm_helm_live_harness "$dir/fixture" codex)
  fm_helm_hold "$home/state" "$pid"

  # A full boot through the emitter, with the real SessionStart payload on stdin
  # and the same environment the boot gates use.
  out=$(fm_boot_hook_json | env \
    FM_HOME="$home" \
    FM_BOOT_FLEET_DIR="$dir/fleet" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$FM_BOOT_EMITTER" 2>&1)
  assert_no_refusal "bin/fm-boot-context.sh" "$out"
  # The second instance ACTIVATES FULLY: it gets the same fleet view, not a stub
  # and not a refusal. That is the whole difference section 4 draws - the presence
  # of another steering session changes the PRESENTATION, never the activation.
  assert_contains "$out" "## Fleet" \
    "a second session must still boot with the full fleet view, not a stub"

  # RECOVERY STEP 1, exactly as AGENTS.md section 5 names it: the BARE acquire.
  # This is the command a second session actually runs at startup, so this is the
  # command the "no error string at boot" property has to hold for.
  out=$(fm_helm_under_harness "$WRAP/boot" claude \
    env FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lock.sh" 2>&1) && code=0 || code=$?
  assert_no_refusal "bare bin/fm-lock.sh (recovery step 1)" "$out"
  expect_code 0 "$code" "the bare acquire is a boot command; finding another steerer is normal, not a failure"
  assert_contains "$out" "observing, not steering" \
    "the bare acquire must still SAY plainly that this session is the observer"
  [ "$(cat "$home/state/.lock")" = "$pid" ] || fail "the bare acquire overwrote a live holder"

  out=$(FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-lock.sh" status 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-lock.sh status" "$out"
  expect_code 0 "$code" "fm-lock.sh status must stay exit 0"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-guard.sh" 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-guard.sh" "$out"
  expect_code 0 "$code" "fm-guard.sh must stay exit 0 - it warns, it never blocks"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-wake-drain.sh" "$out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-watch-arm.sh" --status 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-watch-arm.sh --status" "$out"
  expect_code 0 "$code" "watcher status is read-only and must stay exit 0"

  # Bootstrap, with a toolchain complete enough that it has nothing to report.
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node no-mistakes gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "session list") printf 'name    status\ndefault running\n' ;; esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then printf 'Usage: treehouse get [--lease]\n'; fi
exit 0
SH
  cat > "$fakebin/brew" <<'SH'
#!/usr/bin/env bash
echo "FAKE-BREW-RAN $*"
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/gh" "$fakebin/treehouse" "$fakebin/brew"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-bootstrap.sh" "$out"
  expect_code 0 "$code" "bootstrap must boot normally under a foreign helm"

  # EDGE POLICY: `install` is a separate invocation with different semantics, and
  # it does NOT gate. It runs at boot like the rest of bootstrap, so a refusal
  # here would be exactly the boot-time refusal section 4 rules out; and what it
  # mutates is the machine's tool inventory, not this home's fleet state.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-bootstrap.sh" install tmux 2>&1) && code=0 || code=$?
  assert_no_refusal "fm-bootstrap.sh install" "$out"
  expect_code 0 "$code" "bootstrap install must not gate on the helm"
  assert_contains "$out" "FAKE-BREW-RAN install tmux" "bootstrap install did not actually install"
  pass "no boot path emits a refusal under a live foreign helm - including the bare acquire recovery step 1 names"
}


# The structural half of the same property: the boot and observation scripts must
# not call the seam at all. A behavioural absence can be true by luck of a code
# path; this cannot.
test_seam_roster_is_writer_only() {
  local callers f
  # shellcheck disable=SC2016  # a literal grep pattern; $STATE must NOT expand
  callers=$(grep -l 'fm_lock_require_helm "$STATE"' "$ROOT"/bin/*.sh | while IFS= read -r f; do basename "$f"; done | LC_ALL=C sort | tr '\n' ' ')
  [ "$callers" = "fm-merge-local.sh fm-pr-check.sh fm-promote.sh fm-send.sh fm-spawn.sh fm-teardown.sh fm-update.sh fm-watch-arm.sh " ] \
    || fail "the helm seam's caller roster changed unreviewed: [$callers]"

  for f in fm-bootstrap.sh fm-boot-context.sh fm-captain-bootstrap.sh fm-guard.sh \
           fm-wake-drain.sh fm-watch.sh fm-peek.sh fm-status.sh \
           fm-review-diff.sh fm-fleet-sync.sh fm-harness.sh fm-project-mode.sh; do
    assert_no_grep 'fm_lock_require_helm' "$ROOT/bin/$f" \
      "$f is a boot or read path and must never gate on the helm"
  done
  pass "only the drive verbs gate; every boot and read path is clear of the seam"
}


# EDGE POLICY, harness-not-found, in both directions. Exercised at the function,
# because the ancestry a test runs under is not something it can choose for a
# purely hypothetical case.
# shellcheck disable=SC2030,SC2031  # the subshells here only OVERRIDE
# fm_lock_harness_pid; nothing they set is read back, so the "modified in a
# subshell" warnings are noise.
test_require_helm_policy_matrix() {
  local dir state pid out rc
  dir="$TMP_ROOT/matrix"
  state="$dir/state"
  mkdir -p "$state"
  pid=$(fm_helm_live_harness "$dir/fixture" claude)

  # free -> allowed AND claimed. An advisory check that returns "go ahead" for a
  # free helm without taking it is not a lock: the moment a holder dies, two
  # observers both read free and both drive.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 4242; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a free lock must never refuse a writer"
  [ -z "$out" ] || fail "a free lock must be silent, got: $out"
  [ "$(cat "$state/.lock")" = 4242 ] || fail "proceeding on a free helm must CLAIM it"

  # stale: a recorded holder that is dead is not a steering session; reclaimed.
  printf '99999999\n' > "$state/.lock"
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 4243; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale lock must never refuse a writer"
  [ "$(cat "$state/.lock")" = 4243 ] || fail "proceeding on a stale helm must reclaim it"

  # ours
  fm_helm_hold "$state" "$pid"
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo "$pid"; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "the holder itself must never be refused"
  [ -z "$out" ] || fail "the holder must be waved through silently, got: $out"

  # theirs
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { echo 1; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a live foreign holder must refuse"
  assert_contains "$out" "reading rather than driving" "the refusal must carry the captain-facing sentence"
  [ "$(cat "$state/.lock")" = "$pid" ] || fail "a refused writer overwrote the holder"

  # harness-not-found WITH a live holder -> REFUSED. Waving it through was a
  # bypass: any caller could defeat the helm by detaching from its agent.
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { return 1; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "an unidentifiable harness must not drive past a live holder"
  assert_contains "$out" "could not be identified" "the refusal must say the identity was the problem"
  [ "$(cat "$state/.lock")" = "$pid" ] || fail "an unidentifiable session overwrote a live holder"

  # harness-not-found with NOBODY steering -> allowed, out loud, unclaimed.
  # Refusing here would be a lock-out by another route: such a session could never
  # drive anything, and --take needs an identity too.
  rm -f "$state/.lock"
  rc=0; out=$(. "$ROOT/bin/fm-lock-lib.sh"
    fm_lock_harness_pid() { return 1; }
    fm_lock_require_helm "$state" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "an unidentifiable harness must not be locked out of an unsteered home"
  assert_contains "$out" "cannot be identified" \
    "failing open must say so; silently skipping the check is the failure mode this policy names"
  assert_not_contains "$out" "refused:" "failing open must not read as a refusal"
  assert_absent "$state/.lock" "a session with no identity has nothing to record, so it must claim nothing"
  pass "helm policy matrix: free and stale are CLAIMED; ours passes; theirs and an unidentified session behind a live holder refuse; an unidentified session on an unsteered home passes, out loud"
}


test_real_lock_untouched() {
  [ "$(fm_helm_real_lock)" = "$REAL_LOCK_BEFORE" ] \
    || fail "this suite changed the captain's real lock at $FM_HELM_REAL_LOCK - it is scoped by FM_STATE_OVERRIDE and must never reach it"
  pass "the captain's real session lock is byte-identical before and after"
}


test_drive_verbs_refuse_and_mutate_nothing
test_a_live_pi_holder_is_not_read_as_dead
test_positive_controls_and_the_claim
test_no_boot_path_refuses
test_seam_roster_is_writer_only
test_require_helm_policy_matrix
test_real_lock_untouched
