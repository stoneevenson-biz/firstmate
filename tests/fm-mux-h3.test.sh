#!/usr/bin/env bash
# GATE h3 - a herdr spawn lands as a NAMED TAB in the RESOLVED workspace.
#
# THE DEFECT. bin/fm-spawn.sh contained zero FM_MUX/fm_mux_ references and drove
# tmux directly, so every crewmate this fleet spawned landed in a tmux session
# the captain cannot see. A pane he cannot see does not count. The seam existed
# and was complete; nothing called it.
#
# WHAT THIS GATE PINS, end to end through fm-spawn.sh with no FM_MUX set:
#   * a reachable herdr server is what the crewmate is created in;
#   * the tab is scoped to the project's workspace, resolved by label;
#   * the tab is NAMED <project>-<work>, never the task id;
#   * the name is one herdr will actually accept as an agent address - the fake
#     enforces herdr 0.8.2's real ^[a-z][a-z0-9_-]{0,31}$ rule, so a slash
#     separator fails here rather than in the captain's sidebar;
#   * the meta records the opaque target AND the driver that minted it, which is
#     what keeps the crewmate steerable later;
#   * the task id stays in the meta and out of the name.
set -u
export FM_INTAKE_OVERRIDE=1   # wardroom: this suite tests spawn machinery, not intake
export FM_SKIP_SHELL_READY=1  # readiness is gated by h5/h7 against live panes

# shellcheck source=tests/mux-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/mux-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux-h3)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

PROJ=$(make_repo "$TMP_ROOT/archify")
git -C "$PROJ" worktree add -q --detach "$TMP_ROOT/wt" >/dev/null 2>&1
WT=$(cd "$TMP_ROOT/wt" && pwd -P)

FB=$(fm_mux_fake_herdr "$TMP_ROOT")
fm_fake_exit0 "$FB" treehouse
CALLS="$TMP_ROOT/calls"; export CALLS

# Spawn with NO FM_MUX set - the whole point is what happens by default. The
# ambient FM_MUX=tmux that tests/lib.sh pins for every other suite is stripped
# here on purpose; FORCE_MUX puts an explicit choice back for the fallback case.
run_spawn() {  # <home> <id> [extra args...]
  local home=$1 id=$2; shift 2
  local forced=()
  [ -z "${FORCE_MUX:-}" ] || forced=("FM_MUX=$FORCE_MUX")
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  env -u FM_MUX "${forced[@]}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_LAUNCH_VERIFY_SLEEP=0 \
    HERDR_SERVER=running \
    HERDR_WORKSPACES="wJ=config,wM=archify" \
    HERDR_PANE_CWD="$WT" \
    HERDR_TABS="$TMP_ROOT/tabs" \
    HERDR_WS_CREATED="$TMP_ROOT/created" \
    CALLS="$CALLS" \
    PATH="$FB:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" codex "$@" 2>&1
}

reset() { : > "$CALLS"; : > "$TMP_ROOT/tabs"; : > "$TMP_ROOT/created"; }

# --- the default lands in herdr ---------------------------------------------

test_no_fm_mux_spawns_into_herdr() {
  reset
  local home out
  home="$TMP_ROOT/home-default"; mkdir -p "$home/data"
  out=$(run_spawn "$home" fleet-view-q4 --name "fleet view")
  assert_contains "$out" "spawned fleet-view-q4" "the spawn did not succeed"
  assert_contains "$out" "mux=herdr" "the spawn did not report herdr as the driver"
  assert_grep "tab create" "$CALLS" "no herdr tab was created - the crewmate went somewhere invisible"
  assert_no_grep "new-window" "$CALLS" "spawn still created a tmux window by default"
  pass "default: with no FM_MUX and a reachable server, the crewmate is a herdr tab"
}

# --- scoped to the project's workspace --------------------------------------

test_tab_is_scoped_to_the_project_workspace() {
  reset
  local home
  home="$TMP_ROOT/home-scope"; mkdir -p "$home/data"
  run_spawn "$home" leak-fixes-b2 --name "leak fixes" >/dev/null
  assert_grep "tab create --workspace wM" "$CALLS" \
    "the tab was not scoped to the archify workspace (it landed wherever focus was)"
  pass "scope: the tab is created in the project's own workspace, resolved by label"
}

# --- named for the work, not the id -----------------------------------------

test_tab_is_named_for_the_work() {
  reset
  local home
  home="$TMP_ROOT/home-name"; mkdir -p "$home/data"
  run_spawn "$home" resources-r7 --name "resource registry" >/dev/null
  assert_grep "--label archify-resource-registry" "$CALLS" \
    "the tab was not labelled <project>-<work>"
  assert_no_grep "--label fm-resources-r7" "$CALLS" \
    "the tab was labelled with the task id - the exact thing a name must not be"
  pass "naming: the tab is labelled archify-resource-registry, not the task id"
}

# The name must be one herdr ACCEPTS. The fake enforces the real 0.8.2 rule, so
# a slash separator makes `agent rename` fail here instead of leaving the
# captain with an unaddressable pane.
test_the_name_is_one_herdr_accepts() {
  reset
  local home
  home="$TMP_ROOT/home-accept"; mkdir -p "$home/data"
  run_spawn "$home" hook-register-c9 --name "hook register" >/dev/null
  assert_grep "agent rename" "$CALLS" "the agent was never given its address"
  assert_grep "agent rename wM:p2 archify-hook-register" "$CALLS" \
    "the agent address is not the hyphen-joined project-first name herdr accepts"
  pass "naming: herdr accepted the name as an agent address (a slash would not be)"
}

# Absent --name, the work half comes from the id with its random suffix dropped.
test_name_defaults_from_the_task_id_without_its_suffix() {
  reset
  local home
  home="$TMP_ROOT/home-derive"; mkdir -p "$home/data"
  run_spawn "$home" boot-activation-k3 >/dev/null
  assert_grep "--label archify-boot-activation" "$CALLS" \
    "the derived name kept the random task suffix"
  pass "naming: an absent --name derives archify-boot-activation from boot-activation-k3"
}

# --- the meta keeps the task id, and the routing -----------------------------

test_meta_records_the_target_and_its_driver() {
  reset
  local home meta
  home="$TMP_ROOT/home-meta"; mkdir -p "$home/data"
  run_spawn "$home" provisioning-m5 --name provisioning >/dev/null
  meta="$home/state/provisioning-m5.meta"
  assert_present "$meta" "no meta was recorded"
  assert_grep "window=wM:p2" "$meta" "the meta does not carry the opaque herdr target"
  assert_grep "mux=herdr" "$meta" \
    "the meta does not record WHICH driver minted the target; a later steer would guess"
  assert_grep "name=archify-provisioning" "$meta" "the meta does not record the pane name"
  assert_grep "worktree=$WT" "$meta" "the worktree was not resolved through the seam's cwd read"
  pass "meta: records the opaque target, the driver that minted it, and the pane name"
}

# The id belongs in the meta and nowhere else. This is the whole naming argument
# in one assertion.
test_the_task_id_lives_in_the_meta_not_the_name() {
  reset
  local home
  home="$TMP_ROOT/home-id"; mkdir -p "$home/data"
  run_spawn "$home" automerge-z1 --name automerge >/dev/null
  # The id addresses the meta - it IS the meta's filename, which is the whole
  # point: firstmate looks a task up by id, the captain looks a pane up by work.
  assert_present "$home/state/automerge-z1.meta" "the id does not address a meta file"
  assert_no_grep "automerge-z1" "$TMP_ROOT/tabs" "the task id leaked into a tab label"
  assert_grep "archify-automerge" "$TMP_ROOT/tabs" "the tab does not carry the work name"
  pass "naming: the id lives in state/<id>.meta; the tab carries the work"
}

# --- the explicit fallback still works --------------------------------------

test_fm_mux_tmux_still_creates_a_tmux_window() {
  reset
  local home out
  home="$TMP_ROOT/home-tmux"; mkdir -p "$home/data"
  out=$(FORCE_MUX=tmux run_spawn "$home" fallback-t8 --name fallback)
  assert_contains "$out" "mux=tmux" "FM_MUX=tmux did not select the tmux driver"
  assert_no_grep "tab create" "$CALLS" "FM_MUX=tmux still created a herdr tab"
  pass "fallback: FM_MUX=tmux keeps creating a tmux window, not a herdr tab"
}

test_no_fm_mux_spawns_into_herdr
test_tab_is_scoped_to_the_project_workspace
test_tab_is_named_for_the_work
test_the_name_is_one_herdr_accepts
test_name_defaults_from_the_task_id_without_its_suffix
test_meta_records_the_target_and_its_driver
test_the_task_id_lives_in_the_meta_not_the_name
test_fm_mux_tmux_still_creates_a_tmux_window
