#!/usr/bin/env bash
# Behavior tests for the herdr library (bin/fm-herdr.sh).
#
# This file used to test a multiplexer SEAM - one contract, two drivers, and the
# rules for choosing between them. There is one surface now, so the interesting
# property is no longer "both drivers agree" but "the verbs do what they say
# against herdr's actual API shapes".
#
# Driver selection and the escalation live in tests/fm-herdr-h1; workspace
# scoping in h2; spawn in h3; steering in h4; the drain in h6/h7; and the live
# server in h5. What is left here is the library's own surface: the JSON
# extraction everything else rests on, and the verbs' call shapes.
#
# All of it runs over a fakebin - no real herdr pane is created.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lib)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls.txt"; export CALLS
export HERDR_WORKSPACES="w9=proj"
export HERDR_TABS="$TMP_ROOT/tabs"
reset_calls() { : > "$CALLS"; : > "$HERDR_TABS"; }

# --- the JSON extraction everything else rests on ---------------------------

# This is the load-bearing primitive: workspace ids, pane ids, tab ids and cwds
# all come out of it. A quote dropped from its pattern makes every one of them
# return empty, and the failures land far away from the cause - which is exactly
# what happened once during the collapse.
test_field_extraction_pulls_real_values() {
  local json
  json='{"id":"cli:pane:get","result":{"pane":{"cwd":"/a/b","foreground_cwd":"/a/b/c","pane_id":"wM:p2","tab_id":"wM:t2"},"type":"pane_info"}}'
  assert_eq "$(fm_herdr_field "$json" pane_id)"        "wM:p2"  "pane_id was not extracted"
  assert_eq "$(fm_herdr_field "$json" tab_id)"         "wM:t2"  "tab_id was not extracted"
  assert_eq "$(fm_herdr_field "$json" foreground_cwd)" "/a/b/c" "foreground_cwd was not extracted"
  assert_eq "$(fm_herdr_field "$json" nosuchkey)"      ""       "a missing key did not yield nothing"
  pass "field: real herdr response shapes yield their values, and a missing key yields nothing"
}

# Records are split before matching, so a key in one object cannot be paired
# with a value from the next.
test_field_extraction_does_not_straddle_records() {
  local json
  json='{"result":{"workspaces":[{"label":"alpha","workspace_id":"w1"},{"label":"beta","workspace_id":"w2"}]}}'
  assert_eq "$(fm_herdr_field "$json" workspace_id)" "w1" \
    "extraction crossed a record boundary"
  pass "field: matching is per-record, not across the whole response"
}

# --- the verbs' call shapes -------------------------------------------------

# A tab create must be workspace-scoped and must hand back the PANE id: that is
# what every agent verb addresses and what the meta records.
test_new_tab_is_scoped_and_returns_the_pane() {
  reset_calls
  local pane
  pane=$(fm_herdr_new_tab w9 proj-work /tmp) || fail "new_tab failed"
  assert_eq "$pane" "w9:p2" "new_tab did not return the pane id"
  assert_grep "tab create --workspace w9" "$CALLS" "the tab was not scoped to a workspace"
  assert_grep "--no-focus" "$CALLS" "creating a tab stole the captain's focus"
  pass "new_tab: workspace-scoped, unfocused, and returns the pane id"
}

# Delivery to an IDLE agent is one acknowledged call. --wait is trustworthy from
# a non-working state, because the binary requires an observed state change
# before it matches - so a match means the agent moved because of this prompt.
#
# This case used to assert --wait on EVERY prompt. That was wrong, and wrong in
# the direction that mattered: from a working agent --wait "does not track
# turns" and can be satisfied by the turn already running, so insisting on it
# there is insisting on the very signal that cannot be trusted. Busy delivery is
# gated in tests/fm-herdr-h10-busy-ack.
test_an_idle_prompt_is_one_acknowledged_call() {
  reset_calls
  HERDR_STATES=idle fm_herdr_prompt w9:p2 "hello" || fail "prompt failed"
  assert_grep "agent prompt w9:p2 hello --wait" "$CALLS" \
    "the idle prompt did not use the acknowledged path"
  assert_grep "--until" "$CALLS" \
    "the idle prompt does not name the states it accepts; herdr's default could change under it"
  pass "prompt: an idle agent gets one acknowledged call, with its states named"
}

# A blocked agent is at an approval dialog. Typing over it is how a prompt gets
# eaten and a decision gets answered by accident.
test_blocked_agent_returns_its_own_code() {
  local rc=0
  HERDR_BLOCKED=1 fm_herdr_prompt w9:p2 "hello" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "a blocked agent did not return the distinct refusal code"
  pass "prompt: a blocked agent returns 3, not a generic failure"
}

# Delivered-but-unacknowledged is its own answer, because re-sending a steer the
# crewmate already has is the worse of the two available errors.
test_a_stall_is_its_own_code() {
  local rc=0
  HERDR_STALLED=1 fm_herdr_prompt w9:p2 "hello" >/dev/null 2>&1 || rc=$?
  expect_code 4 "$rc" "a stalled delivery was not reported as delivered-but-unconfirmed"
  pass "prompt: a stall returns 4 - delivered, unconfirmed, never re-sent"
}

# busy is a real lifecycle state, not a regex over rendered text. That is the
# single largest thing herdr buys over the pane-scraping it replaced.
test_is_busy_reads_a_real_state() {
  AGENT_STATE=working fm_herdr_is_busy w9:p2 || fail "missed a working agent"
  AGENT_STATE=idle    fm_herdr_is_busy w9:p2 && fail "called an idle agent busy"
  pass "is_busy: reads herdr's lifecycle state rather than scraping the pane"
}

test_read_returns_pane_text() {
  HERDR_PANE_FILE="$TMP_ROOT/pane.txt"; export HERDR_PANE_FILE
  printf 'line-one\nline-two\n' > "$HERDR_PANE_FILE"
  fm_herdr_read w9:p2 | grep -q line-two || fail "read lost content"
  pass "read: returns the pane's text"
}

# THE DEFECT THIS FREEZES (Quarterdeck reject, attempt 1). fm_herdr_prompt ran
# `herdr agent prompt ... || true`, discarding the exit status, then matched
# stdout against a short list of known error strings. Anything unmatched fell
# through to `*) return 0` - the function's own contract for "delivered AND
# ACKNOWLEDGED". A stub exiting 7 with `socket closed: connection reset by peer`
# reproduced RC=0, and fm-send exited 0 with no warning for a steer that was
# never delivered.
#
# That is the worst failure this seam can have. The acknowledgment is the whole
# reason herdr replaced blind keystrokes; reporting a network drop as a
# confirmed steer is worse than tmux ever was, because tmux at least never
# claimed to know. The exit STATUS is authoritative; the message only refines
# which kind of failure it was.
test_a_nonzero_exit_is_never_reported_as_acknowledged() {
  local rc=0
  HERDR_PROMPT_RC=7 HERDR_PROMPT_OUT='socket closed: connection reset by peer'     fm_herdr_prompt w9:p2 'git reset --hard origin/main' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    fail "herdr failed with exit 7 and the steer was reported as delivered AND acknowledged"
  fi
  if [ "$rc" = 4 ]; then
    fail "a hard failure was reported as delivered-but-unconfirmed; nothing was delivered"
  fi
  expect_code 1 "$rc" "a hard delivery failure did not report failure"
  pass "prompt: a nonzero herdr exit is a failure, whatever the message says"
}

# The mirror case: a zero exit that still carries an error envelope. Trusting
# only the status would swap one blind spot for another.
test_an_error_envelope_is_a_failure_even_on_exit_zero() {
  local rc=0
  HERDR_PROMPT_RC=0 HERDR_PROMPT_OUT='{"error":{"code":"bad_request","message":"nope"}}'     fm_herdr_prompt w9:p2 'hello' >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an error envelope on a zero exit was reported as success"
  pass "prompt: an error envelope fails even when the process exited zero"
}

# A pane with no detected agent must NOT have the steer executed in it. herdr's
# `pane run` submits a SHELL COMMAND LINE, so forwarding a raw steer there means
# a crewmate instruction like `git reset --hard origin/main` runs as a command
# in the worktree. The honest answer is that there is no agent to steer.
test_an_undetected_agent_never_executes_the_steer_as_a_shell_command() {
  reset_calls
  local rc=0
  HERDR_NO_AGENT=1 fm_herdr_prompt w9:p2 'git reset --hard origin/main' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ] || [ "$rc" = 4 ]; then
    fail "a pane with no agent reported the steer as delivered (rc=$rc)"
  fi
  assert_no_grep "pane run" "$CALLS"     "the steer was forwarded to 'pane run' and would have EXECUTED as a shell command"
  pass "prompt: with no agent detected, nothing is executed and the steer is refused"
}

# A failed create must be reported, not papered over with a target that does not
# exist - that is how firstmate records a meta for a pane holding nothing.
test_a_failed_create_is_reported() {
  reset_calls
  if fm_herdr_new_tab "" proj-work /tmp >/dev/null 2>&1; then
    fail "an unscoped tab create was treated as success"
  fi
  pass "new_tab: a failed create is reported, not papered over"
}

test_field_extraction_pulls_real_values
test_field_extraction_does_not_straddle_records
test_new_tab_is_scoped_and_returns_the_pane
test_an_idle_prompt_is_one_acknowledged_call
test_blocked_agent_returns_its_own_code
test_a_stall_is_its_own_code
test_a_nonzero_exit_is_never_reported_as_acknowledged
test_an_error_envelope_is_a_failure_even_on_exit_zero
test_an_undetected_agent_never_executes_the_steer_as_a_shell_command
test_is_busy_reads_a_real_state
test_read_returns_pane_text
test_a_failed_create_is_reported
