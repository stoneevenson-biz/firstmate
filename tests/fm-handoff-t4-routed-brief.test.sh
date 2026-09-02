#!/usr/bin/env bash
# gate-t4-routed-brief-reports-to-destination
#
# A backlog item handed to a secondmate must take its REPORTING CHANNEL with it.
# bin/fm-brief.sh pins the home into the fm-status.sh command, so an item routed
# with that pin left behind gives the destination a task it owns and a channel
# it does not: the crewmate's reports land in the origin's state dir, which the
# owning supervisor's watcher never polls.
#
# This gate proves the CHANNEL moved, not that a string changed. It scaffolds a
# real ship brief with the real bin/fm-brief.sh, hands the item off, then
# EXTRACTS THE BRIEF'S OWN reporting command from the destination copy and RUNS
# it. The assertion is where the line landed: the destination's state dir, and
# not the origin's. Asserting the brief text changed would pass for a rewrite
# that still resolved to the wrong home - which is the whole defect.
#
# Three arms, because the defect has three shapes:
#   A. an item routed with its brief - the brief dir travels and the command
#      names the destination home, its state dir, and its own fm-status.sh.
#   B. an item routed BEFORE this existed - already in the destination backlog
#      and destination data/, but still pinned to the origin. Re-running the
#      handoff is the repair path, so the same run that moves new items converges
#      old ones instead of leaving them silently misrouted.
#   C. a destination home with no bin/fm-status.sh of its own - the pins still
#      move, and the command keeps the script path it had rather than naming a
#      file that does not exist.
#
# Mutation (LEDGER_MUTATE=1): each arm's landing assertion is inverted to demand
# the line arrive in the ORIGIN's state dir. A retargeted brief then fails,
# which keys this gate to where reports actually go.
#
# spec: docs/specs/2026-09-01-routed-brief-home.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-handoff-t4-routed)

HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
BRIEF_SH="$ROOT/bin/fm-brief.sh"
assert_present "$HANDOFF" "bin/fm-backlog-handoff.sh must exist"
assert_present "$BRIEF_SH" "bin/fm-brief.sh must exist"

# make_world <name> <with-own-status-script> -> echoes "<origin> <dest>"
make_world() {
  local name=$1 own_script=$2 origin dest
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
  printf 'design\n' > "$dest/.fm-secondmate-home"
  printf -- '- demo [local-only] - demo project (added 2026-09-01)\n' > "$origin/data/projects.md"
  printf -- '- design - feature work (home: %s; scope: features; projects: demo; added 2026-09-01)\n' \
    "$dest" > "$origin/data/secondmates.md"
  cat > "$origin/data/backlog.md" <<'BACKLOG'
## In flight

## Queued
- [ ] feat-x - add feature x (repo: demo)
- [ ] scout-x - investigate the thing (repo: demo)

## Done
BACKLOG
  # A destination home that carries its own copy of the reporting script is the
  # ordinary case (every secondmate home is a firstmate worktree); one without
  # is arm C.
  if [ "$own_script" = own ]; then
    cp "$ROOT/bin/fm-status.sh" "$dest/bin/fm-status.sh"
  fi
  printf '%s %s\n' "$origin" "$dest"
}

# Pull the brief's OWN reporting command out of it and run it with a real
# message. One backticked command per status line; take the first and strip the
# ticks - the same extraction the fm-status-verb gate uses, so this gate judges
# the command a crewmate is really handed rather than a restatement of it.
run_brief_report() {
  local brief=$1 msg=$2 form
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks are literal.
  form=$(grep -m1 -F 'fm-status.sh' "$brief" | sed -n 's/^[^`]*`\(.*\)`[^`]*$/\1/p')
  [ -n "$form" ] \
    || fail "could not extract the reporting command from $brief - this gate must run the emitted form, not a restatement of it"
  form=${form//\{state\}: \{one short line\}/$msg}
  eval "$form" || fail "the brief's own reporting command failed to run: $form"
}

# assert_landed <origin> <dest> <key> <msg>: the report reached the destination
# home's state dir and NOT the origin's. Inverted under LEDGER_MUTATE.
assert_landed() {
  local origin=$1 dest=$2 key=$3 msg=$4 label=$5
  if [ "${LEDGER_MUTATE:-}" = 1 ]; then
    assert_present "$origin/state/$key.status" \
      "MUTATION ($label): expected the report to still land in the ORIGIN state dir"
    assert_grep "$msg" "$origin/state/$key.status" \
      "MUTATION ($label): expected the origin status file to carry the report"
    return 0
  fi
  assert_present "$dest/state/$key.status" \
    "$label: the report did not reach the destination home's state dir"
  assert_grep "$msg" "$dest/state/$key.status" \
    "$label: the destination status file does not carry the reported line"
  assert_absent "$origin/state/$key.status" \
    "$label: the report still landed in the ORIGIN home's state dir - the channel did not move"
}

# --- A. an item routed with its brief ---------------------------------------
test_routed_item_reports_to_destination() {
  local origin dest out world
  world=$(make_world a own)
  origin=${world% *}
  dest=${world#* }

  FM_HOME="$origin" bash "$BRIEF_SH" feat-x demo >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the ship brief"
  assert_present "$origin/data/feat-x/brief.md" "the origin brief must exist before the handoff"

  out=$(FM_HOME="$origin" bash "$HANDOFF" design feat-x) \
    || fail "handoff failed for an in-scope item carrying a brief"
  assert_contains "$out" "handed off 1 item(s) to design" "handoff did not report the moved item"

  # The brief travels: the destination home can dispatch it, and the origin no
  # longer holds a second copy for the same task.
  assert_present "$dest/data/feat-x/brief.md" "the brief did not travel to the destination home"
  assert_absent "$origin/data/feat-x" "the origin kept a copy of the routed brief"

  run_brief_report "$dest/data/feat-x/brief.md" "done: routed report"
  assert_landed "$origin" "$dest" feat-x "done: routed report" "routed item"

  # And the command names the destination's own script, not the origin's.
  assert_grep "bash '$dest/bin/fm-status.sh'" "$dest/data/feat-x/brief.md" \
    "the retargeted command must run the destination home's own fm-status.sh"
  pass "a routed item's brief reports into the destination home, not the origin"
}

# --- B. an item routed before the channel travelled --------------------------
#
# The fixture models THE STATE THE PRE-FIX CODE ACTUALLY PRODUCED, which is the
# only state the repair path has to converge: the backlog line was moved to the
# destination and the data/<key>/ dir was left behind in the origin, because the
# old code moved lines and nothing else. A fixture that pre-copies the dir to the
# destination models a state that code could not reach, and would miss the
# defect where the repair leaves the dir in BOTH homes.
test_rerun_repairs_an_already_routed_item() {
  local origin dest out world
  world=$(make_world b own)
  origin=${world% *}
  dest=${world#* }

  FM_HOME="$origin" bash "$BRIEF_SH" feat-x demo >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the ship brief"
  cat > "$dest/data/backlog.md" <<'BACKLOG'
## In flight

## Queued
- [ ] feat-x - add feature x (repo: demo)

## Done
BACKLOG
  # main no longer carries the line - the old code moved that much and no more.
  cat > "$origin/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
  assert_present "$origin/data/feat-x/brief.md" \
    "fixture precondition: the pre-fix state leaves the brief dir in the origin"
  assert_absent "$dest/data/feat-x" \
    "fixture precondition: the destination has no copy of the dir yet"
  assert_grep "FM_HOME='$origin'" "$origin/data/feat-x/brief.md" \
    "fixture precondition: the already-routed brief must still pin the origin home"

  out=$(FM_HOME="$origin" bash "$HANDOFF" design feat-x) \
    || fail "re-running the handoff for an already-routed item must succeed"
  assert_contains "$out" "already present" "the re-run should report the item as already present"
  assert_contains "$out" "retargeted" "the re-run should report the repaired reporting channel"

  # The repair is a FULL migration, not just a rewrite: one home ends up owning
  # the item, and the run says which dir it moved rather than leaving a second
  # copy behind unmentioned.
  assert_present "$dest/data/feat-x/brief.md" "the repair did not carry the brief to the destination"
  assert_absent "$origin/data/feat-x" \
    "the repair left the brief dir in BOTH homes - the duplicate-ownership half of the defect"
  assert_contains "$out" "brief dir moved" "the repair must name the dir it moved"

  run_brief_report "$dest/data/feat-x/brief.md" "done: repaired report"
  assert_landed "$origin" "$dest" feat-x "done: repaired report" "repaired item"
  pass "re-running a handoff fully migrates an item routed before the channel travelled"
}

# --- C. a destination with no fm-status.sh of its own ------------------------
test_destination_without_its_own_script() {
  local origin dest world
  world=$(make_world c none)
  origin=${world% *}
  dest=${world#* }

  FM_HOME="$origin" bash "$BRIEF_SH" feat-x demo >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the ship brief"
  FM_HOME="$origin" bash "$HANDOFF" design feat-x >/dev/null \
    || fail "handoff failed against a destination with no fm-status.sh"

  # The pins moved; the script path stayed on a file that exists rather than
  # being pointed at one the destination does not have.
  assert_grep "FM_HOME='$dest'" "$dest/data/feat-x/brief.md" \
    "the reporting command must pin the destination home"
  assert_no_grep "bash '$dest/bin/fm-status.sh'" "$dest/data/feat-x/brief.md" \
    "the command must not name a script the destination home does not have"

  run_brief_report "$dest/data/feat-x/brief.md" "done: no-script report"
  assert_landed "$origin" "$dest" feat-x "done: no-script report" "destination without its own script"
  pass "the channel moves even when the destination has no fm-status.sh of its own"
}

# --- D. a routed SCOUT's deliverable ----------------------------------------
#
# A scout's channel is not its status file, it is the REPORT. bin/fm-brief.sh
# pins that as an absolute path, and bin/fm-teardown.sh reads $DATA/$ID/report.md
# from its OWN home - so a report path left at the origin means the crewmate
# writes the findings into a home that no longer owns the task (and which the
# handoff has just emptied), the owning secondmate never sees the deliverable,
# and its teardown refuses because the report it looks for is not there.
#
# Proven the same way as the status arm: take the path THE BRIEF NAMES, write the
# report to it, and assert whose home it landed in.
test_routed_scout_reports_to_destination() {
  local origin dest world named
  world=$(make_world d own)
  origin=${world% *}
  dest=${world#* }

  FM_HOME="$origin" bash "$BRIEF_SH" scout-x demo --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh must scaffold the scout brief"
  assert_grep "$origin/data/scout-x/report.md" "$origin/data/scout-x/brief.md" \
    "fixture precondition: the scout brief must pin the origin's report path"

  FM_HOME="$origin" bash "$HANDOFF" design scout-x >/dev/null \
    || fail "handoff failed for a scout item"

  # The path the crewmate is told to write to, read back out of the brief it
  # receives rather than restated here.
  named=$(grep -m1 -o "/[^\`]*/scout-x/report.md" "$dest/data/scout-x/brief.md")
  [ -n "$named" ] || fail "the routed scout brief names no absolute report path"

  mkdir -p "$(dirname "$named")"
  printf 'findings\n' > "$named"

  if [ "${LEDGER_MUTATE:-}" = 1 ]; then
    assert_present "$origin/data/scout-x/report.md" \
      "MUTATION: expected the scout report to still land in the ORIGIN home"
    pass "MUTATION arm reached"
    return 0
  fi

  # This is the exact expression bin/fm-teardown.sh reads in the owning home:
  # $DATA/$ID/report.md, with DATA=<home>/data.
  assert_present "$dest/data/scout-x/report.md" \
    "the scout's deliverable did not land where the owning home's teardown reads it"
  assert_absent "$origin/data/scout-x" \
    "the scout wrote its report back into the origin home, which no longer owns the task"

  run_brief_report "$dest/data/scout-x/brief.md" "done: scout reported"
  assert_landed "$origin" "$dest" scout-x "done: scout reported" "routed scout"
  pass "a routed scout's report lands in the home whose teardown reads it"
}

test_routed_item_reports_to_destination
test_rerun_repairs_an_already_routed_item
test_destination_without_its_own_script
test_routed_scout_reports_to_destination
