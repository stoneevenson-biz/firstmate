#!/usr/bin/env bash
# gate-t4-handoff-safety-preserved
#
# Routing the reporting channel with the item made bin/fm-backlog-handoff.sh
# move FILES as well as a backlog line, so its refusals now have more to protect
# than they did. This gate holds the pre-existing safety properties against the
# harder case - every one of them exercised with a brief dir present:
#
#   1. an unmatched key aborts atomically: neither backlog is touched AND the
#      brief dir is still whole in the origin.
#   2. an `## In flight` item is refused, and its brief does not travel.
#   3. a destination lacking the `.fm-secondmate-home` marker is refused, and
#      nothing is written into it.
#   4. the move is idempotent: a second run duplicates no line, moves no brief a
#      second time, and leaves the retargeted command exactly as it was.
#   5. a destination that already holds its own data/<key>/ keeps it. The
#      destination's copy is the live one, so it is neither clobbered nor
#      deleted from under whoever wrote it; the origin's stale copy is NAMED in
#      the output rather than silently removed.
#
# Mutation (LEDGER_MUTATE=1): arm 1's atomicity assertion is inverted to demand
# that the refused run moved the brief dir anyway. An atomic abort then fails.
#
# spec: docs/specs/2026-09-01-routed-brief-home.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-handoff-t4-safety)

HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
BRIEF_SH="$ROOT/bin/fm-brief.sh"
assert_present "$HANDOFF" "bin/fm-backlog-handoff.sh must exist"

# make_world <name> [marker-id] -> echoes "<origin> <dest>"; the destination is
# a seeded secondmate home unless <marker-id> is "none", which models a home
# that is not one.
make_world() {
  local name=$1 marker=${2:-design} origin dest
  origin="$TMP/$name-main"
  dest="$TMP/$name-sub"
  mkdir -p "$origin/data" "$origin/state" "$origin/projects/demo"
  mkdir -p "$dest/data" "$dest/state" "$dest/bin"
  # Resolve both homes the way the script does (pwd -P), so an assertion on an
  # emitted path is comparing like with like on a platform where $TMPDIR is a
  # symlink - which macOS's /tmp is.
  origin=$(cd "$origin" && pwd -P)
  dest=$(cd "$dest" && pwd -P)
  printf '# Firstmate\n' > "$dest/AGENTS.md"
  [ "$marker" = none ] || printf '%s\n' "$marker" > "$dest/.fm-secondmate-home"
  cp "$ROOT/bin/fm-status.sh" "$dest/bin/fm-status.sh"
  printf -- '- demo [local-only] - demo project (added 2026-09-01)\n' > "$origin/data/projects.md"
  printf -- '- design - feature work (home: %s; scope: features; projects: demo; added 2026-09-01)\n' \
    "$dest" > "$origin/data/secondmates.md"
  cat > "$origin/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] live-task - active work (repo: demo, since 2026-09-01)

## Queued
- [ ] feat-x - add feature x (repo: demo)

## Done
BACKLOG
  FM_HOME="$origin" bash "$BRIEF_SH" feat-x demo >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the queued item's brief"
  FM_HOME="$origin" bash "$BRIEF_SH" live-task demo >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the in-flight item's brief"
  printf '%s %s\n' "$origin" "$dest"
}

# --- 1. an unmatched key aborts atomically, brief included -------------------
test_unmatched_key_aborts_atomically() {
  local origin dest before world
  world=$(make_world unmatched)
  origin=${world% *}
  dest=${world#* }
  before=$(cat "$origin/data/backlog.md")

  if FM_HOME="$origin" bash "$HANDOFF" design feat-x no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi

  if [ "${LEDGER_MUTATE:-}" = 1 ]; then
    assert_absent "$origin/data/feat-x/brief.md" \
      "MUTATION: expected the refused run to have moved the brief dir anyway"
    pass "MUTATION arm reached"
    return 0
  fi

  [ "$before" = "$(cat "$origin/data/backlog.md")" ] \
    || fail "an unmatched key still mutated the main backlog"
  assert_present "$origin/data/feat-x/brief.md" \
    "an unmatched key moved the valid item's brief out of the origin"
  assert_absent "$dest/data/feat-x" \
    "an unmatched key left a brief dir behind in the destination home"
  pass "an unmatched key aborts atomically: backlog and brief both untouched"
}

# --- 2. an in-flight item is refused, and its brief stays --------------------
test_in_flight_is_refused_with_its_brief() {
  local origin dest before world
  world=$(make_world inflight)
  origin=${world% *}
  dest=${world#* }
  before=$(cat "$origin/data/backlog.md")

  if FM_HOME="$origin" bash "$HANDOFF" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$origin/data/backlog.md")" ] \
    || fail "the in-flight refusal mutated the main backlog"
  assert_present "$origin/data/live-task/brief.md" \
    "the in-flight refusal moved the live task's brief out of the origin"
  assert_absent "$dest/data/live-task" \
    "the in-flight refusal copied the live task's brief into the secondmate home"
  pass "an in-flight item is refused and its brief does not travel"
}

# --- 3. a destination that is not a seeded secondmate home is refused --------
test_unseeded_destination_is_refused() {
  local origin dest world
  world=$(make_world unseeded none)
  origin=${world% *}
  dest=${world#* }

  if FM_HOME="$origin" bash "$HANDOFF" design feat-x >/dev/null 2>&1; then
    fail "handoff accepted a destination with no .fm-secondmate-home marker"
  fi
  assert_absent "$dest/data/feat-x" \
    "the unseeded destination was written into anyway"
  assert_absent "$dest/data/backlog.md" \
    "the unseeded destination received a backlog"
  assert_present "$origin/data/feat-x/brief.md" \
    "the refused handoff moved the brief out of the origin"

  # And a marker naming a different secondmate is refused the same way.
  printf 'someone-else\n' > "$dest/.fm-secondmate-home"
  if FM_HOME="$origin" bash "$HANDOFF" design feat-x >/dev/null 2>&1; then
    fail "handoff accepted a home marked for a different secondmate"
  fi
  assert_absent "$dest/data/feat-x" \
    "a mismatched marker still let the brief through"
  pass "a destination that is not this secondmate's seeded home is refused, briefs included"
}

# --- 4. idempotent: line, brief and command all converge --------------------
test_idempotent_rerun() {
  local origin dest first second world
  world=$(make_world idempotent)
  origin=${world% *}
  dest=${world#* }

  FM_HOME="$origin" bash "$HANDOFF" design feat-x >/dev/null \
    || fail "first handoff failed"
  first=$(cat "$dest/data/feat-x/brief.md")

  FM_HOME="$origin" bash "$HANDOFF" design feat-x >/dev/null \
    || fail "idempotent re-run failed"
  second=$(cat "$dest/data/feat-x/brief.md")

  [ "$(grep -cF -- '- [ ] feat-x - add feature x (repo: demo)' "$dest/data/backlog.md")" -eq 1 ] \
    || fail "the re-run duplicated the item in the destination backlog"
  [ "$first" = "$second" ] \
    || fail "the re-run changed an already-retargeted brief"
  assert_grep 'live-task' "$origin/data/backlog.md" \
    "the re-run disturbed the in-flight item left in the main backlog"
  pass "a re-run duplicates no line and rewrites no already-retargeted brief"
}

# --- 5. a destination that already holds its own copy keeps it --------------
test_destination_copy_is_not_clobbered() {
  local origin dest out world
  world=$(make_world collision)
  origin=${world% *}
  dest=${world#* }

  mkdir -p "$dest/data/feat-x"
  printf 'the live destination copy\n' > "$dest/data/feat-x/notes.md"
  cp "$origin/data/feat-x/brief.md" "$dest/data/feat-x/brief.md"
  printf 'ORIGIN-ONLY MARKER\n' >> "$origin/data/feat-x/brief.md"

  out=$(FM_HOME="$origin" bash "$HANDOFF" design feat-x) \
    || fail "handoff failed when the destination already held a brief dir"

  assert_grep 'the live destination copy' "$dest/data/feat-x/notes.md" \
    "the destination's own copy was clobbered by the origin's"
  assert_no_grep 'ORIGIN-ONLY MARKER' "$dest/data/feat-x/brief.md" \
    "the origin's copy overwrote the destination's live brief"
  assert_present "$origin/data/feat-x/brief.md" \
    "the origin's copy was deleted even though it was never migrated"
  assert_contains "$out" "left in place" \
    "the stranded origin copy must be named in the output, not silently ignored"
  # The destination's own copy is still retargeted - it is the one that runs.
  assert_grep "FM_HOME='$dest'" "$dest/data/feat-x/brief.md" \
    "the destination's own brief was not retargeted at the destination home"
  pass "a destination that already holds a brief dir keeps it, retargeted, and the origin's is named"
}

test_unmatched_key_aborts_atomically
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  exit 0
fi
test_in_flight_is_refused_with_its_brief
test_unseeded_destination_is_refused
test_idempotent_rerun
test_destination_copy_is_not_clobbered
