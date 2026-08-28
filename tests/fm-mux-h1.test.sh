#!/usr/bin/env bash
# GATE h1 - driver selection: herdr by default, tmux only as a LOUD fallback.
#
# THE CAPTAIN'S STANDING RULE: "I always want agents spawned in herdr."
# A pane he cannot see does not count, so the default with no FM_MUX set must be
# herdr - not tmux, and not "herdr if we happen to be running inside it".
#
# WHY REACHABILITY, NOT HERDR_ENV. The seam used to select herdr only when
# HERDR_ENV=1. Live evidence killed that predicate: HERDR_ENV is UNSET in
# firstmate's own process while a herdr server is running and the captain is
# watching it. Under the old rule every crewmate landed in an invisible tmux
# session while the captain believed he was watching the fleet. The correct
# question is not "am I inside herdr" but "is a herdr server reachable".
#
# WHY THE FALLBACK MUST BE LOUD. An unconditional herdr default would break
# every context with no server - cron, CI, a plain SSH session - so the seam
# still degrades to tmux. But a SILENT degrade recreates the original bug in a
# worse form: the captain believes he is watching the fleet in herdr while the
# crew land somewhere he cannot see. Degrading is allowed; degrading quietly is
# not.
set -u

# shellcheck source=tests/mux-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/mux-helpers.sh"
# shellcheck source=bin/fm-mux-lib.sh
. "$ROOT/bin/fm-mux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux-h1)
FB=$(fm_mux_fake_herdr "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
: > "$CALLS"

# Each case runs the resolution in a fresh subshell: the announcement is
# once-per-process by design, so a shared shell would hide the second one.
resolve_in() {  # <env-assignments...> -> "driver|stderr"
  local out err
  err=$(mktemp "$TMP_ROOT/err.XXXXXX")
  # shellcheck disable=SC2016  # $0 is the sourced lib path, expanded by the inner shell
  out=$(env "$@" bash -c '. "$0"; fm_mux_driver' "$ROOT/bin/fm-mux-lib.sh" 2>"$err")
  printf '%s|%s' "$out" "$(tr '\n' ' ' < "$err")"
}

# --- the default ------------------------------------------------------------

test_default_is_herdr_when_a_server_is_reachable() {
  local got=${1:-}
  got=$(resolve_in FM_MUX= HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "default: no FM_MUX and a reachable server must select herdr"
  pass "default: a reachable herdr server is chosen with no FM_MUX set"
}

# The predicate that matters. HERDR_ENV is unset in firstmate's own process
# right now while the captain watches a live server; if selection consulted it,
# every crewmate would land in tmux.
test_herdr_env_is_not_the_predicate() {
  local got
  got=$(resolve_in FM_MUX= HERDR_ENV= HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "selection must key off reachability, not HERDR_ENV"
  pass "default: chosen on reachability, with HERDR_ENV unset"
}

# --- the fallback, and its volume -------------------------------------------

test_stopped_server_falls_back_to_tmux() {
  local got
  got=$(resolve_in FM_MUX= HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" tmux "a stopped server must degrade to tmux, not strand the spawn"
  pass "fallback: a stopped herdr server degrades to tmux instead of failing"
}

test_missing_binary_falls_back_to_tmux() {
  local got clean
  clean=$(fm_mux_path_without_herdr)
  got=$(resolve_in FM_MUX= "PATH=$clean" "CALLS=$CALLS")
  assert_eq "${got%%|*}" tmux "an absent binary must degrade to tmux"
  pass "fallback: no herdr binary degrades to tmux (cron, CI, plain SSH keep working)"
}

# The whole point. A silent fallback is the failure this gate exists to prevent.
test_fallback_says_so_on_stderr() {
  local got err
  got=$(resolve_in FM_MUX= HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  err=${got#*|}
  case "$err" in
    *tmux*) : ;;
    *) fail "fallback was SILENT; stderr said: '$err'" ;;
  esac
  case "$err" in
    *"no herdr server"*) : ;;
    *) fail "fallback did not say WHY it fell back; stderr said: '$err'" ;;
  esac
  pass "fallback: names the driver chosen and the reason, on stderr"
}

test_missing_binary_fallback_names_that_reason() {
  local got err clean
  clean=$(fm_mux_path_without_herdr)
  got=$(resolve_in FM_MUX= "PATH=$clean" "CALLS=$CALLS")
  err=${got#*|}
  case "$err" in
    *"not on PATH"*) pass "fallback: an absent binary is reported as its own distinct reason" ;;
    *) fail "absent binary reported as: '$err'" ;;
  esac
}

# --- the override, both directions ------------------------------------------

test_explicit_tmux_wins_over_a_live_server() {
  local got
  got=$(resolve_in FM_MUX=tmux HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" tmux "FM_MUX=tmux must win over a live herdr server"
  pass "override: FM_MUX=tmux wins even with a herdr server up (the rollback switch)"
}

# An explicit choice is not a degrade, so it must NOT be announced - otherwise
# every headless cron spawn prints a warning about a decision the operator made.
test_explicit_tmux_is_not_announced() {
  local got err
  got=$(resolve_in FM_MUX=tmux HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  err=$(printf '%s' "${got#*|}" | tr -d ' ')
  assert_eq "$err" "" "an explicit FM_MUX=tmux is a choice, not a degrade; it must not warn"
  pass "override: an explicit FM_MUX=tmux is silent, not warned about"
}

test_explicit_herdr_wins_over_an_unreachable_server() {
  local got
  got=$(resolve_in FM_MUX=herdr HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "FM_MUX=herdr must be honoured without a reachability veto"
  pass "override: FM_MUX=herdr is honoured without a reachability veto"
}

test_unknown_driver_refuses() {
  if FM_MUX=screen fm_mux_read foo >/dev/null 2>&1; then
    fail "unknown driver silently accepted"
  else
    pass "an unknown FM_MUX driver is refused, not ignored"
  fi
}

test_default_is_herdr_when_a_server_is_reachable
test_herdr_env_is_not_the_predicate
test_stopped_server_falls_back_to_tmux
test_missing_binary_falls_back_to_tmux
test_fallback_says_so_on_stderr
test_missing_binary_fallback_names_that_reason
test_explicit_tmux_wins_over_a_live_server
test_explicit_tmux_is_not_announced
test_explicit_herdr_wins_over_an_unreachable_server
test_unknown_driver_refuses
