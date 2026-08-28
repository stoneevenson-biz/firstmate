#!/usr/bin/env bash
# GATE h7 - a LIVE tmux pane, end to end through the seam.
#
# WHY THIS EXISTS ALONGSIDE THE FAKES. Every other tmux case in this repo runs
# over a fakebin, and a fake answers whatever it was written to answer. A seam
# verb can satisfy a recorded call sequence perfectly and still not drive a real
# terminal - wrong quoting, a target shape tmux rejects, a capture that returns
# nothing. So one gate in the tmux direction talks to a REAL tmux server, in its
# own throwaway session, and does the whole loop:
#
#   scope -> window_exists -> new_window -> run -> cwd -> wait_ready
#         -> run_launch -> read -> send_key -> close
#
# It creates and destroys its own session; it never touches the fleet's.
set -u
export FM_MUX=tmux

# shellcheck source=tests/mux-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/mux-helpers.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-mux-lib.sh
. "$ROOT/bin/fm-mux-lib.sh"

if ! command -v tmux >/dev/null 2>&1; then
  printf 'not ok - GATE h7 cannot run: tmux is not installed\n' >&2
  printf '  this gate must exercise a LIVE pane; a skip here is a gap, not a pass\n' >&2
  exit 1
fi

TMP_ROOT=$(fm_test_tmproot fm-mux-h7)
SES="fmh7-$$"
WORKDIR="$TMP_ROOT/work"; mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd -P)
TARGET=""

cleanup() {
  [ -z "$TARGET" ] || tmux kill-window -t "$TARGET" 2>/dev/null || true
  tmux kill-session -t "$SES" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

tmux new-session -d -s "$SES" -c "$WORKDIR" 2>/dev/null \
  || fail "could not start a throwaway tmux session"

# --- the live loop ----------------------------------------------------------

test_live_window_lifecycle() {
  # A window that does not exist yet must not be reported as existing - the
  # duplicate-spawn guard depends on this answer being real.
  if fm_mux_window_exists "$SES" fm-h7 fm-h7; then
    fail "window_exists claimed a window that was never created"
  fi

  TARGET=$(fm_mux_new_window "$SES" fm-h7 "$WORKDIR" fm-h7) \
    || fail "new_window failed against a live tmux server"
  assert_eq "$TARGET" "$SES:fm-h7" "the live target is not the expected session:window"

  if ! fm_mux_window_exists "$SES" fm-h7 fm-h7; then
    fail "window_exists did not see a window that tmux really has"
  fi
  pass "live tmux: new_window creates a real window, and window_exists sees it"
}

# The readiness probe is the guard that stops a launch line being typed into a
# shell that is not at a prompt - the failure that left two dead secondmates on
# 2026-08-26. Over a fake it is a formality; against a real shell it is a test.
test_live_shell_readiness() {
  if ! FM_SHELL_READY_TIMEOUT=20 fm_mux_wait_ready "$TARGET" 20; then
    fail "wait_ready never got its marker back from a real shell"
  fi
  pass "live tmux: wait_ready proves a real shell reached a prompt"
}

test_live_run_and_read() {
  local marker out waited
  marker="h7live$$"
  fm_mux_run "$TARGET" "printf '%s\\n' $marker-ran" || fail "run failed against a live pane"
  out=""
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    out=$(fm_mux_read "$TARGET" 40)
    case "$out" in *"$marker-ran"*) break ;; esac
    sleep 0.25
  done
  assert_contains "$out" "$marker-ran" "read never saw the output of a command run in a real pane"
  pass "live tmux: run executes in the pane and read returns what it printed"
}

# run_launch carries the LONG literal line: quotes, $(...), embedded JSON. This
# is the shape that broke on 2026-08-26 when it reached the shell as text.
test_live_run_launch_carries_a_literal_line() {
  local marker out waited
  marker="h7launch$$"
  fm_mux_run_launch "$TARGET" "printf '%s\\n' \"\$(printf '%s' $marker-literal)\"" \
    || fail "run_launch failed against a live pane"
  out=""
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    out=$(fm_mux_read "$TARGET" 40)
    case "$out" in *"$marker-literal"*) break ;; esac
    sleep 0.25
  done
  assert_contains "$out" "$marker-literal" "run_launch did not deliver a literal command line intact"
  # And the pane must not be showing a shell error from mangled quoting.
  if fm_mux_launch_failed "$TARGET"; then
    fail "run_launch left a shell error in the pane: $(fm_mux_read "$TARGET" 10)"
  fi
  pass "live tmux: run_launch delivers a quoted, substituted line without a shell error"
}

test_live_cwd_tracks_the_pane() {
  local sub got waited
  sub="$WORKDIR/deeper"; mkdir -p "$sub"
  sub=$(cd "$sub" && pwd -P)
  got=$(fm_mux_cwd "$TARGET")
  assert_eq "$got" "$WORKDIR" "cwd did not report the pane's starting directory"
  # The treehouse-get wait loop depends on this CHANGING when the pane chdirs.
  fm_mux_run "$TARGET" "cd '$sub'"
  got=""
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    got=$(fm_mux_cwd "$TARGET")
    [ "$got" = "$sub" ] && break
    sleep 0.25
  done
  assert_eq "$got" "$sub" "cwd did not follow a real chdir; the worktree wait would hang"
  pass "live tmux: cwd reports the pane's real directory and follows a chdir"
}

# The launch-failure detector must fire on a REAL shell error, not just on a
# fixture string. Otherwise a dead pane gets a meta recorded for it.
test_live_launch_failure_is_detected() {
  local waited
  fm_mux_run "$TARGET" "definitely-not-a-real-command-h7"
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    fm_mux_launch_failed "$TARGET" && break
    sleep 0.25
  done
  if ! fm_mux_launch_failed "$TARGET"; then
    fail "a real 'command not found' was not detected: $(fm_mux_read "$TARGET" 10)"
  fi
  pass "live tmux: a real shell error is detected, not assumed away"
}

test_live_send_key_reaches_the_pane() {
  # C-c on a sleeping foreground command: the shell returns to a prompt, which
  # the readiness probe can then prove.
  fm_mux_run "$TARGET" "sleep 30"
  sleep 1
  fm_mux_send_key "$TARGET" C-c || fail "send_key failed against a live pane"
  if ! FM_SHELL_READY_TIMEOUT=15 fm_mux_wait_ready "$TARGET" 15; then
    fail "send_key C-c did not return the real shell to a prompt"
  fi
  pass "live tmux: send_key delivers a control key that the real shell acts on"
}

test_live_close_removes_the_window() {
  fm_mux_close "$TARGET"
  local waited gone=0
  waited=0
  while [ "$waited" -lt 20 ]; do
    waited=$((waited + 1))
    if ! fm_mux_window_exists "$SES" fm-h7 fm-h7; then gone=1; break; fi
    sleep 0.25
  done
  [ "$gone" = 1 ] || fail "close did not remove the live window"
  TARGET=""
  pass "live tmux: close tears the real window down"
}

test_live_window_lifecycle
test_live_shell_readiness
test_live_run_and_read
test_live_run_launch_carries_a_literal_line
test_live_cwd_tracks_the_pane
test_live_launch_failure_is_detected
test_live_send_key_reaches_the_pane
test_live_close_removes_the_window
