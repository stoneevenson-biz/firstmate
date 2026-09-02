#!/usr/bin/env bash
# GATE h12 - `--name` plans by default, and applies BOTH slots or neither.
#
# TWO DEFECTS, one verb.
#
# 1. It mutated on sight. Every other verb in this CLI plans by default and
#    changes nothing until --apply, so the same script disagreed with itself
#    about what running it bare does: bare reconcile printed a plan, bare --name
#    renamed a live pane. A verb whose dry run is indistinguishable from its
#    real run is one an operator has to test on production.
#
# 2. It renames TWO objects - the tab label the captain reads and the agent
#    address herdr steers by - and a failure between them leaves a pane whose
#    visible name reaches nothing. That is the mystery-agent state the naming
#    rule exists to remove: the captain addresses the name he can see, herdr
#    says no such agent, and nothing in the fleet records which pane it was.
#
# THE ORDER IS NOT ARBITRARY, and this gate pins the reason. A rollback can only
# restore a value it can read back, and herdr 0.8.2's AgentInfo carries no name
# field at all - the readable name lives on the TAB (`tab get`). So the tab goes
# first, because it is the only slot that can be put back.
#
# Mutation (LEDGER_MUTATE=1): the library is copied with the plan default
# flipped to apply, and the rollback rename replaced by a no-op - the two
# behaviours this gate exists to hold.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h12)
SCRIPT="$ROOT/bin/fm-herdr.sh"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  SCRIPT="$TMP_ROOT/mutated-fm-herdr.sh"
  # shellcheck disable=SC2016  # literal sed patterns: they must not expand here
  sed -e 's/local APPLY=0 cli_args=()/local APPLY=1 cli_args=()/' \
      -e 's/if fm_herdr_rename_slot "\$first" "\$pane" "\$tab" "\$prior"/if true/' \
      "$ROOT/bin/fm-herdr.sh" > "$SCRIPT"
fi

FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
export HERDR_TAB_LABEL=1          # herdr's own default tab label, pre-naming

HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects/afs"
printf -- '- afs [local-only] - a project (added 2026-09-01)\n' > "$HOME_DIR/data/projects.md"

run_name() {  # <args...>
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --name "$@" 2>&1
}

# --- plan by default --------------------------------------------------------

test_name_without_apply_renames_nothing() {
  local out rc=0
  out=$(run_name w9:p2 afs "resource registry") || rc=$?
  [ "$rc" = 0 ] || fail "the plan run failed (exit $rc): $out"
  assert_contains "$out" "afs-resource-registry" "the plan does not say what it would name the pane"
  assert_contains "$out" "plan only" "the plan run does not say it changed nothing"
  assert_no_grep "tab rename"   "$CALLS" "planning renamed the tab"
  assert_no_grep "agent rename" "$CALLS" "planning renamed the agent"
  pass "name: plans by default - it says what it would do and changes nothing"
}

test_apply_names_both_slots() {
  local out rc=0
  out=$(run_name w9:p2 afs "resource registry" --apply) || rc=$?
  [ "$rc" = 0 ] || fail "the apply run failed (exit $rc): $out"
  assert_grep "tab rename"   "$CALLS" "--apply did not rename the tab"
  assert_grep "agent rename w9:p2 afs-resource-registry" "$CALLS" "--apply did not name the agent"
  pass "name: --apply names both slots with the same string"
}

# --apply may appear anywhere; it must never be swallowed into the work words,
# which would silently name a pane `afs-resource-registry-apply`.
test_apply_is_a_flag_not_a_word_of_the_work() {
  run_name w9:p2 afs --apply "resource registry" >/dev/null 2>&1
  assert_grep "agent rename w9:p2 afs-resource-registry" "$CALLS" \
    "--apply leaked into the name or was not recognised before the work words"
  assert_no_grep "apply-" "$CALLS" "--apply was treated as part of the work"
  pass "name: --apply is a flag wherever it appears, never a word of the work"
}

# THE FLAG MUST NOT DECIDE WHICH VERB RUNS. Dispatch used to read only $1, so
# `--apply --name ...` matched no verb, fell through to the workspace reconcile,
# and the reconcile read the same flag and CREATED WORKSPACES: an operator asking
# to rename one pane got a different mutating verb, silently, with exit 0. This
# is that exact command line.
test_apply_before_the_verb_still_names_and_creates_nothing() {
  local out rc=0
  : > "$CALLS"
  out=$(FM_HOME="$HOME_DIR" bash "$SCRIPT" --apply --name w9:p2 afs "resource registry" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "--apply before the verb failed (exit $rc): $out"
  assert_grep "agent rename w9:p2 afs-resource-registry" "$CALLS" \
    "--apply before the verb did not reach --name; the flag chose the verb"
  assert_no_grep "workspace create" "$CALLS" \
    "--apply before the verb ran the workspace reconcile instead of the rename"
  assert_not_contains "$out" "would name" "--apply before the verb was treated as a plan"
  pass "name: --apply BEFORE the verb still names, and creates no workspace"
}

# And the flag still selects nothing on its own: bare --apply is the reconcile,
# exactly as before, so making it position-independent did not make it a verb.
test_bare_apply_is_still_the_reconcile() {
  local out
  : > "$CALLS"
  out=$(FM_HOME="$HOME_DIR" bash "$SCRIPT" --apply 2>&1)
  assert_contains "$out" "PROJECT" "bare --apply no longer runs the workspace reconcile"
  assert_no_grep "agent rename" "$CALLS" "bare --apply renamed something"
  pass "name: bare --apply is still the workspace reconcile, not a rename"
}

# --- the order, and the reason for it ---------------------------------------

test_the_readable_slot_is_renamed_first() {
  local first
  run_name w9:p2 afs "resource registry" --apply >/dev/null 2>&1
  first=$(grep -E '^(tab|agent) rename' "$CALLS" | head -1 | awk '{print $1}')
  assert_eq "$first" "${fm_herdr_name_order%% *}" \
    "the slots were not renamed in the declared order"
  assert_eq "${fm_herdr_name_order%% *}" tab \
    "the first slot must be the one whose prior value can be read back (herdr exposes no agent name)"
  pass "name: the readable slot (tab) is renamed first, so a rollback is possible"
}

# --- all or nothing ---------------------------------------------------------

# THE HALF-NAMED PANE. The agent rename is refused for a name that is perfectly
# valid - a duplicate address, a permission error, a server problem. The tab
# must not be left carrying a name that reaches nothing.
test_a_refused_agent_rename_rolls_the_tab_back() {
  local out rc=0 renames
  : > "$CALLS"
  out=$(HERDR_RENAME_REFUSE=1 FM_HOME="$HOME_DIR" \
          bash "$SCRIPT" --name w9:p2 afs "resource registry" --apply 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a refused agent rename was reported as success: $out"
  renames=$(grep -c '^tab rename' "$CALLS")
  [ "$renames" = 2 ] || fail "expected the tab renamed then rolled back (2 tab renames), got $renames: $(cat "$CALLS")"
  grep -q "^tab rename .* $HERDR_TAB_LABEL\$" "$CALLS" \
    || fail "the tab was not rolled back to its previous label: $(cat "$CALLS")"
  pass "name: a refused agent rename rolls the tab back - no half-named pane"
}

# THE ONE HALF-NAME THAT IS DELIBERATE, pinned here so it stays deliberate.
# herdr classifies an agent a beat after launch, so `agent_not_found` means "not
# yet", not "refused" - the spawn path depends on that, and a spawn must not die
# waiting for a classification. Nothing is rolled back, because there is no agent
# to be misaddressed: the tab carries the name and the pane holds no address yet.
# It says so rather than reporting a clean success.
test_an_unclassified_agent_keeps_the_name_and_is_reported() {
  local out rc=0
  : > "$CALLS"
  out=$(HERDR_NO_AGENT=1 FM_HOME="$HOME_DIR" \
          bash "$SCRIPT" --name w9:p2 afs "resource registry" --apply 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "an agent herdr has not classified yet was treated as a failure: $out"
  assert_contains "$out" "no agent detected" "the tab-only outcome was reported as a clean rename"
  [ "$(grep -c '^tab rename' "$CALLS")" = 1 ] \
    || fail "the tab was rolled back for an agent that simply is not classified yet: $(cat "$CALLS")"
  pass "name: an unclassified agent keeps the tab name and is reported, not rolled back"
}

# The rollback is not silent. If it could not happen, the operator has to be
# told which pane is half-named, or the mystery agent is back with no record.
test_a_rollback_that_cannot_happen_is_reported() {
  local out rc=0
  : > "$CALLS"
  out=$(HERDR_RENAME_REFUSE=1 HERDR_TAB_LABEL='' FM_HOME="$HOME_DIR" \
          bash "$SCRIPT" --name w9:p2 afs "resource registry" --apply 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a refused agent rename was reported as success: $out"
  assert_contains "$out" "w9:p2" "the report does not name the pane that is half-named"
  pass "name: a rollback that cannot happen is reported, naming the pane"
}

# An invalid name never reaches herdr at all, in either mode: the refusal is
# firstmate's, so a plan run refuses exactly what an apply run would.
test_an_unusable_name_is_refused_in_both_modes() {
  local plan_rc=0 apply_rc=0
  run_name w9:p2 afs "an extremely long description of the work that never fits" >/dev/null 2>&1 || plan_rc=$?
  run_name w9:p2 afs "an extremely long description of the work that never fits" --apply >/dev/null 2>&1 || apply_rc=$?
  [ "$plan_rc" != 0 ]  || fail "an overlong name was accepted by the plan run"
  [ "$apply_rc" != 0 ] || fail "an overlong name was accepted by the apply run"
  assert_no_grep "rename" "$CALLS" "an unusable name still reached herdr"
  pass "name: an unusable name is refused identically by plan and apply"
}

# shellcheck source=bin/fm-herdr.sh
. "$SCRIPT"

test_name_without_apply_renames_nothing
test_apply_names_both_slots
test_apply_is_a_flag_not_a_word_of_the_work
test_apply_before_the_verb_still_names_and_creates_nothing
test_bare_apply_is_still_the_reconcile
test_the_readable_slot_is_renamed_first
test_a_refused_agent_rename_rolls_the_tab_back
test_an_unclassified_agent_keeps_the_name_and_is_reported
test_a_rollback_that_cannot_happen_is_reported
test_an_unusable_name_is_refused_in_both_modes
