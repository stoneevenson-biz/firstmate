#!/usr/bin/env bash
# GATE h6 - the drain stays open, and nothing new is created on tmux.
#
# WHAT THIS GATE USED TO SAY, AND WHY IT CHANGED. It froze the exact sequence of
# tmux calls fm-spawn emitted, so that FM_MUX=tmux was provably a byte-identical
# rollback. That property is gone on purpose: with herdr the only surface there
# is no tmux spawn path left to be identical to, and a gate asserting parity
# with a retired path would keep passing while measuring nothing. A gate whose
# text stays put while its meaning drifts is worse than no gate.
#
# WHAT IS ACTUALLY TRUE AFTER THE CUTOVER, and is gated here instead:
#
#   1. NOTHING NEW IS CREATED ON TMUX. No spawn, under any environment, puts an
#      agent in a tmux window. The old FM_MUX=tmux override cannot bring it back.
#
#   2. THE DRAIN STAYS OPEN. Crewmates spawned BEFORE the cutover live in tmux
#      windows; their state/<id>.meta has no `mux=herdr` line. Those must stay
#      readable AND steerable AND closable until they are torn down. A watcher
#      that cannot read a live crewmate is blind; a supervisor that can watch
#      one but not correct it has lost half of supervision; and a teardown that
#      cannot close one strands work carrying unlanded commits. Removing the
#      drain would be a self-inflicted outage, so it is gated, not trusted.
#
#   3. THE DRAIN IS DERIVED, NOT LISTED. Which windows are draining is read from
#      the metas, never from a hardcoded inventory. A list has to be right, and
#      the one this migration was handed was not: it named four windows, missed
#      three live crewmates whose metas sit in another firstmate home, and named
#      two whose metas the author had not enumerated. A meta-derived rule is
#      correct under any inventory, and it closes by itself.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h6)
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"

# A pre-cutover meta: a tmux window, no mux= line, because the seam that would
# have written one did not exist when it was spawned. This is the real shape -
# verified against every live meta in every firstmate home at cutover time, none
# of which carried a mux= key.
cat > "$STATE/drainer.meta" <<META
window=firstmate:fm-drainer
worktree=/wt
project=/p/thing
harness=claude
kind=ship
META
# A post-cutover meta: a herdr pane, marked as such.
cat > "$STATE/moderne.meta" <<META
window=wM:p4
worktree=/wt
project=/p/thing
harness=claude
mux=herdr
name=thing-fleet-view
kind=ship
META

# --- 1. nothing new is created on tmux --------------------------------------

test_no_script_can_spawn_onto_tmux() {
  # The spawn path names exactly one surface. If a tmux window-create ever
  # reappears in it, an agent can land where the captain cannot see it.
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -qE 'tmux (new-window|new-session|has-session)'; then
    fail "fm-spawn can still create a tmux window or session"
  fi
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -q 'FM_MUX'; then
    fail "the retired FM_MUX override is still read by fm-spawn"
  fi
  pass "cutover: fm-spawn cannot create a tmux window, and the old override is gone"
}

test_the_collapsed_libraries_are_gone() {
  assert_absent "$ROOT/bin/fm-mux-lib.sh" "the driver-selection library survived the collapse"
  assert_absent "$ROOT/bin/fm-herdr-workspaces.sh" "the workspaces script survived the collapse"
  assert_present "$ROOT/bin/fm-herdr.sh" "the collapsed library is missing"
  # Not a bare `herdr`: that would shadow the real binary at ~/.local/bin/herdr
  # and make which one a call site got depend on PATH order.
  assert_absent "$ROOT/bin/herdr" "a bare 'herdr' script would shadow the real binary"
  pass "cutover: one library, named so it cannot shadow the binary"
}

# --- 2. the drain stays open ------------------------------------------------

test_a_pre_cutover_meta_resolves_to_the_drain() {
  fm_herdr_resolve fm-drainer "$STATE" || fail "a pre-cutover meta would not resolve"
  assert_eq "$FM_HERDR_TARGET" "firstmate:fm-drainer" "the drain target was lost"
  assert_eq "$FM_HERDR_DRAIN" "1" "a pre-cutover meta was not marked for the drain"
  pass "drain: a meta with no mux=herdr resolves as a draining tmux window"
}

test_a_post_cutover_meta_does_not() {
  fm_herdr_resolve fm-moderne "$STATE" || fail "a post-cutover meta would not resolve"
  assert_eq "$FM_HERDR_TARGET" "wM:p4" "the herdr pane id was lost"
  assert_eq "$FM_HERDR_DRAIN" "0" "a herdr crewmate was sent down the drain path"
  pass "drain: a meta with mux=herdr is addressed as herdr, never drained"
}

# The three verbs the constraint names. Losing any one is an outage: read is
# supervision, send is correction, close is cleanup.
test_the_drain_keeps_read_send_and_close_reachable() {
  local peek send
  peek=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-peek.sh")
  send=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-send.sh")
  case "$peek" in
    *"FM_HERDR_DRAIN"*) : ;;
    *) fail "fm-peek has no drain branch; a live pre-cutover crewmate is unreadable" ;;
  esac
  case "$peek" in
    *"capture-pane"*) : ;;
    *) fail "fm-peek can no longer read a tmux pane; the watcher would go blind" ;;
  esac
  case "$send" in
    *"FM_HERDR_DRAIN"*) : ;;
    *) fail "fm-send has no drain branch; a live pre-cutover crewmate is unsteerable" ;;
  esac
  case "$send" in
    *"fm_tmux_submit_core"*) : ;;
    *) fail "fm-send can no longer submit to a tmux pane; steering a draining crewmate would break" ;;
  esac
  # Close is teardown's, and it was deliberately never migrated - which is what
  # keeps it working for the drain.
  case "$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-teardown.sh")" in
    *"tmux kill-window"*) : ;;
    *) fail "teardown can no longer close a tmux window; draining work would be stranded" ;;
  esac
  pass "drain: read, send and close all remain reachable for a draining window"
}

test_the_drain_library_is_retired_not_deleted() {
  assert_present "$ROOT/bin/fm-tmux-lib.sh" \
    "fm-tmux-lib.sh was deleted while windows are still draining; supervision and cleanup would both break"
  # Retired means NO NEW USE: the spawn path must not touch it.
  if grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-spawn.sh" | grep -q 'fm-tmux-lib.sh'; then
    fail "the spawn path still sources the retired tmux library"
  fi
  pass "drain: fm-tmux-lib.sh is retired for new use, and kept while the drain is open"
}

# --- 3. the drain is derived, and it closes by itself ------------------------

test_drain_pending_is_computed_from_metas() {
  if ! fm_herdr_drain_pending "$STATE"; then
    fail "a state dir holding a pre-cutover meta reported no drain pending"
  fi
  # Remove the only pre-cutover meta and the drain closes - no list to edit.
  rm -f "$STATE/drainer.meta"
  if fm_herdr_drain_pending "$STATE"; then
    fail "the drain stayed open with every meta marked mux=herdr"
  fi
  pass "drain: pending is computed from the metas, and closes when the last one is gone"
}

# An empty or absent state dir is not a drain - it is nothing to drain.
test_an_empty_home_has_no_drain() {
  mkdir -p "$TMP_ROOT/empty-state"
  if fm_herdr_drain_pending "$TMP_ROOT/empty-state"; then
    fail "an empty state dir reported a drain pending"
  fi
  if fm_herdr_drain_pending "$TMP_ROOT/no-such-dir"; then
    fail "a missing state dir reported a drain pending"
  fi
  pass "drain: an empty or absent home has nothing to drain"
}

test_no_script_can_spawn_onto_tmux
test_the_collapsed_libraries_are_gone
test_a_pre_cutover_meta_resolves_to_the_drain
test_a_post_cutover_meta_does_not
test_the_drain_keeps_read_send_and_close_reachable
test_the_drain_library_is_retired_not_deleted
test_drain_pending_is_computed_from_metas
test_an_empty_home_has_no_drain
