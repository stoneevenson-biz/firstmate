#!/usr/bin/env bash
# GATE t4-state-residue - a torn-down task leaves ZERO state named after it.
#
# THE DEFECT THIS FREEZES. bin/fm-teardown.sh removed the window, the worktree
# and the seven state files it knew by name, and left behind every marker
# bin/fm-watch.sh had minted for that task: `.seen-<id>_status`,
# `.seen-<id>_turn-ended`, and the per-pane `.hash-`/`.count-`/`.stale-` trio.
# Nothing ever removed them, because the code that creates them and the code
# that ends the task each knew half the naming rule and neither knew the
# other's. Measured on the captain's home on 2026-09-02: 195 entries in state/,
# of which 9 belonged to live work.
#
# IT IS NOT MERELY UNTIDY. Every one of those names is a SUPPRESSOR. `.seen-*`
# means "this signal was already reported" and `.stale-*` means "this exact
# stalled state was already reported", so a task id or a pooled pane id that
# comes back around inherits a marker that silences its first real wake. The
# residue is a supervision hazard with a long fuse.
#
# WHAT MAKES THIS GATE MORE THAN A LIST CHECKED AGAINST ITSELF. The markers are
# minted by RUNNING THE REAL WATCHER, not written by the test from names it
# guessed, so what teardown must remove is whatever fm-watch.sh actually creates.
# And the residue assertion SCANS the state dir for anything still named after
# the task instead of re-reading the prune list, so a state file added to the
# fleet tomorrow and forgotten in that list fails here rather than accumulating.
#
# Mutation (LEDGER_MUTATE=1): put one marker back immediately after teardown
# returns. A correct teardown removed it; the assertion must notice it is there
# again, which proves the check inspects the state dir rather than passing
# vacuously.
set -u

# shellcheck source=tests/watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-helpers.sh"
# shellcheck source=bin/fm-ctx-lib.sh
. "$ROOT/bin/fm-ctx-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-t4-residue)

ID=hygiene-k3
PANE=wZ:p1
# The test's OWN copy of the transform. Deliberately not fm_state_key: a gate
# that asked the implementation what the names are could only ever prove the
# implementation agrees with itself.
KEY=$(printf '%s' "$PANE" | tr ':/.' '___')

# make_case <name>: a watcher-shaped case (herdr + tmux fakes in one fakebin),
# plus the git project and worktree teardown needs, plus a treehouse stub.
make_case() {
  local name=$1 dir
  dir=$(fm_watch_case "$TMP_ROOT" "$name")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/treehouse"
  chmod +x "$dir/fakebin/treehouse"
  fm_git_init_commit "$dir/project"
  git -C "$dir/project" worktree add -q --detach "$dir/wt" HEAD
  {
    printf 'window=%s\n' "$PANE"
    printf 'worktree=%s\n' "$dir/wt"
    printf 'project=%s\n' "$dir/project"
    printf 'harness=claude\nmux=herdr\nkind=ship\nmode=local-only\n'
  } > "$dir/state/$ID.meta"
  printf '%s\n' "$dir"
}

# mint_markers <dir>: run the REAL watcher until it has minted every marker this
# gate is about - the per-pane stale trio, then both signal suppressors.
mint_markers() {
  local dir=$1
  local state="$dir/state"
  # Cycle one: a wedged pane. Primed one cycle from the decision, so this run
  # advances .count-, keeps .hash-, writes .stale- and exits on the stale wake.
  fm_watch_prime "$state" "$PANE" unknown
  HERDR_SNAPSHOT_AGENTS="$PANE=unknown" fm_watch_run "$dir" >/dev/null
  # Cycle two: a status line and a turn-end marker, which the signal scan
  # reports as one wake and records in .seen-<id>_status / .seen-<id>_turn-ended.
  printf 'working: mid-flight\n' > "$state/$ID.status"
  touch "$state/$ID.turn-ended"
  HERDR_SNAPSHOT_AGENTS="$PANE=unknown" fm_watch_run "$dir" >/dev/null
}

assert_minted() {
  local state=$1 f
  for f in ".hash-$KEY" ".count-$KEY" ".stale-$KEY" ".seen-${ID}_status" ".seen-${ID}_turn-ended"; do
    [ -e "$state/$f" ] || fail "fixture: the watcher never minted $f, so this gate would pass vacuously"
  done
}

run_teardown() {
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$ID" "$@"
}

# residue <state>: everything still named after this task, scanned rather than
# listed. The gate's independent oracle.
residue() {
  local state=$1 f base
  for f in "$state"/* "$state"/.*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      .|..) continue ;;
      "$ID".*|.seen-"$ID"_*|*-"$KEY"|*-"$KEY".*) printf '%s\n' "$base" ;;
    esac
  done
}

test_teardown_leaves_no_state_named_after_the_task() {
  local dir state rc left
  dir=$(make_case clean); state="$dir/state"
  mint_markers "$dir"
  assert_minted "$state"

  set +e
  run_teardown "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown failed: $(cat "$dir/stderr")"

  [ "${LEDGER_MUTATE:-}" = 1 ] && printf 'unknown' > "$state/.hash-$KEY"

  left=$(residue "$state")
  [ -z "$left" ] || fail "teardown left state named after $ID; every one of these is a suppressor that silences the next wake for a recycled id or pooled pane:"$'\n'"$left"
  pass "t4: a torn-down task leaves zero state markers for its id"
}

# The one file that must SURVIVE, and the reason the prune is not a blunt
# wildcard: a close that could not happen leaves <id>.orphan-pane as the only
# durable record naming the leftover pane. The markers still go.
test_a_failed_close_keeps_only_the_orphan_record() {
  local dir state rc left
  dir=$(make_case orphan); state="$dir/state"
  mint_markers "$dir"
  assert_minted "$state"
  # A herdr that reports the pane as present and refuses to close it.
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Present, and will not close: the one case teardown must not swallow.
exit 1
SH
  chmod +x "$dir/fakebin/herdr"

  set +e
  run_teardown "$dir" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown should still complete its own cleanup: $(cat "$dir/stderr")"

  assert_present "$state/$ID.orphan-pane" \
    "the only durable record of the leftover pane was pruned with the markers"
  left=$(residue "$state" | grep -vFx "$ID.orphan-pane" || true)
  [ -z "$left" ] || fail "a failed close left more than the orphan record behind:"$'\n'"$left"
  pass "t4: a failed close keeps the orphan record and nothing else"
}

# One rule, one implementation. fm-watch.sh mints these names and fm-teardown.sh
# removes them, so both ask fm_state_key; the context watchdog sanitises the same
# pane identity for its own sentinels. If those two ever disagree, one side's
# files become unreachable to the other - which is how this defect started.
test_the_marker_key_rule_has_one_answer() {
  local raw
  # shellcheck source=bin/fm-state-lib.sh
  . "$ROOT/bin/fm-state-lib.sh"
  for raw in 'wZ:p1' 'firstmate:fm-task-x1' 'a.b/c' 'plain'; do
    assert_eq "$(fm_state_key "$raw")" "$(fm_ctx_sanitize_key "$raw")" \
      "fm_state_key and fm_ctx_sanitize_key disagree on '$raw'; one side's files are unreachable to the other"
  done
  pass "t4: the marker-key rule gives one answer across the fleet"
}

test_teardown_leaves_no_state_named_after_the_task
test_a_failed_close_keeps_only_the_orphan_record
test_the_marker_key_rule_has_one_answer
