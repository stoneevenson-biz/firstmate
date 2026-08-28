#!/usr/bin/env bash
# GATE h1 - herdr is the ONLY default. Headless is never selected automatically.
#
# THE CAPTAIN'S RULE (data/captain.md, "Where agents run", 2026-08-28):
#
#   "Headless is not an automatic fallback and must never be selected by a
#    reachability rule. Any tier may *recommend* a headless run, but it asks me
#    first... Silent degradation to headless is the specific failure this rule
#    exists to prevent - believing I am watching the fleet while work happens
#    somewhere I cannot see is worse than knowing it is invisible."
#
# So there is no probe that decides. With no FM_MUX set the driver is herdr,
# full stop - whether or not a server is reachable, whether or not the binary is
# installed. Reachability still gets CHECKED, but only to escalate: an
# unreachable herdr stops the work and asks, it does not quietly pick something
# else.
#
# WHAT THIS REPLACES. An earlier revision of this gate pinned a reachability
# rule: herdr when a server answered, tmux otherwise, announced on stderr. The
# announcement made the degradation loud, but loud is not the same as asked -
# it still chose headless on the fleet's behalf. That is the rule this file now
# reads the other way round.
#
# FM_MUX remains the explicit, human-chosen override. That is not a fallback; it
# is the captain (or an operator he authorised) saying which multiplexer to use.
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

# Each case resolves in a fresh subshell so nothing carries over.
resolve_in() {  # <env-assignments...> -> "driver|stderr"
  local out err
  err=$(mktemp "$TMP_ROOT/err.XXXXXX")
  # shellcheck disable=SC2016  # $0 is the sourced lib path, expanded by the inner shell
  out=$(env "$@" bash -c '. "$0"; fm_mux_driver' "$ROOT/bin/fm-mux-lib.sh" 2>"$err")
  printf '%s|%s' "$out" "$(tr '\n' ' ' < "$err")"
}

# --- the default is herdr, unconditionally -----------------------------------

test_default_is_herdr_with_a_server_up() {
  local got
  got=$(resolve_in FM_MUX= HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "no FM_MUX must select herdr"
  pass "default: herdr, with a server up"
}

# THE LOAD-BEARING CASE. A stopped server must NOT change the answer. If this
# ever returns tmux, the fleet has silently gone headless behind the captain.
test_default_is_still_herdr_with_no_server() {
  local got
  got=$(resolve_in FM_MUX= HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "an unreachable server must NOT auto-select headless"
  pass "default: still herdr with the server stopped - reachability does not decide"
}

# Nor may an absent binary decide. "herdr isn't installed" is a thing to raise
# with the captain, not a licence to run somewhere he cannot see.
test_default_is_still_herdr_with_no_binary() {
  local got clean
  clean=$(fm_mux_path_without_herdr)
  got=$(resolve_in FM_MUX= "PATH=$clean" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "an absent herdr binary must NOT auto-select headless"
  pass "default: still herdr with no binary installed"
}

test_default_ignores_herdr_env_entirely() {
  local a b
  a=$(resolve_in FM_MUX= HERDR_ENV=1 HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  b=$(resolve_in FM_MUX= HERDR_ENV= HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${a%%|*}" herdr "HERDR_ENV=1 changed the answer"
  assert_eq "${b%%|*}" herdr "HERDR_ENV unset changed the answer"
  pass "default: HERDR_ENV is not consulted in either direction"
}

# No probe means no probe. Selecting the driver must not even ASK the server,
# because a rule that asks is a rule that can answer 'headless'.
test_selection_does_not_probe_the_server() {
  : > "$CALLS"
  resolve_in FM_MUX= HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS" >/dev/null
  assert_no_grep "session list" "$CALLS" \
    "driver selection probed the server; a reachability rule is exactly what must not decide"
  pass "default: selection consults nothing - there is no reachability rule to go wrong"
}

# --- no code path auto-selects headless --------------------------------------

# The blunt sweep: across every combination of server state, binary presence and
# HERDR_ENV, with no FM_MUX set, the answer is herdr every single time.
test_no_combination_ever_auto_selects_tmux() {
  local server binary env_var got clean
  clean=$(fm_mux_path_without_herdr)
  for server in running stopped; do
    for binary in present absent; do
      for env_var in 1 ''; do
        if [ "$binary" = present ]; then
          got=$(resolve_in FM_MUX= "HERDR_SERVER=$server" "HERDR_ENV=$env_var" "PATH=$PATH" "CALLS=$CALLS")
        else
          got=$(resolve_in FM_MUX= "HERDR_SERVER=$server" "HERDR_ENV=$env_var" "PATH=$clean" "CALLS=$CALLS")
        fi
        if [ "${got%%|*}" != herdr ]; then
          fail "auto-selected '${got%%|*}' for server=$server binary=$binary HERDR_ENV='$env_var'"
        fi
      done
    done
  done
  pass "no combination of server, binary or environment ever auto-selects headless"
}

# --- unreachable herdr is an ESCALATION -------------------------------------

# Reachability is still checked - it just escalates instead of deciding. The
# message has to be one the captain can act on: what is wrong, and what he would
# have to say to authorise a headless run.
test_unreachable_herdr_escalates_with_an_actionable_message() {
  local out rc=0
  out=$(HERDR_SERVER=stopped FM_MUX=herdr bash -c \
        '. "$0"; fm_mux_require_available' "$ROOT/bin/fm-mux-lib.sh" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "an unreachable herdr was treated as fine"; fi
  assert_contains "$out" "no herdr server" "the escalation does not name the problem"
  assert_contains "$out" "FM_MUX=tmux" "the escalation does not say how the captain can authorise headless"
  assert_contains "$out" "captain" "the escalation does not say whose decision this is"
  pass "escalation: an unreachable herdr stops and asks, naming the problem and the decision"
}

test_reachable_herdr_passes_the_precondition() {
  local rc=0
  HERDR_SERVER=running FM_MUX=herdr bash -c \
    '. "$0"; fm_mux_require_available' "$ROOT/bin/fm-mux-lib.sh" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a reachable herdr server failed the precondition"
  pass "escalation: a reachable server passes the precondition silently"
}

# An explicitly chosen tmux is a decision already made. It must not be second
# guessed, and it must not be gated on a herdr server existing.
test_explicit_tmux_passes_the_precondition() {
  local rc=0
  HERDR_SERVER=stopped FM_MUX=tmux bash -c \
    '. "$0"; fm_mux_require_available' "$ROOT/bin/fm-mux-lib.sh" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an explicitly chosen tmux was blocked by a herdr precondition"
  pass "escalation: an explicit FM_MUX=tmux is a decision, not a degradation"
}

# --- the explicit override, both directions ----------------------------------

test_explicit_tmux_is_honoured() {
  local got
  got=$(resolve_in FM_MUX=tmux HERDR_SERVER=running "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" tmux "FM_MUX=tmux was not honoured"
  pass "override: FM_MUX=tmux is honoured - the captain's word, not a fallback"
}

test_explicit_choice_is_silent() {
  local got
  got=$(resolve_in FM_MUX=tmux HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "$(printf '%s' "${got#*|}" | tr -d ' ')" "" \
    "an explicit choice printed a warning about a decision the operator already made"
  pass "override: an explicit choice is silent"
}

test_explicit_herdr_is_honoured() {
  local got
  got=$(resolve_in FM_MUX=herdr HERDR_SERVER=stopped "PATH=$PATH" "CALLS=$CALLS")
  assert_eq "${got%%|*}" herdr "FM_MUX=herdr was not honoured"
  pass "override: FM_MUX=herdr is honoured"
}

test_unknown_driver_refuses() {
  if FM_MUX=screen fm_mux_read foo >/dev/null 2>&1; then
    fail "unknown driver silently accepted"
  else
    pass "an unknown FM_MUX driver is refused, not ignored"
  fi
}

test_default_is_herdr_with_a_server_up
test_default_is_still_herdr_with_no_server
test_default_is_still_herdr_with_no_binary
test_default_ignores_herdr_env_entirely
test_selection_does_not_probe_the_server
test_no_combination_ever_auto_selects_tmux
test_unreachable_herdr_escalates_with_an_actionable_message
test_reachable_herdr_passes_the_precondition
test_explicit_tmux_passes_the_precondition
test_explicit_tmux_is_honoured
test_explicit_choice_is_silent
test_explicit_herdr_is_honoured
test_unknown_driver_refuses
