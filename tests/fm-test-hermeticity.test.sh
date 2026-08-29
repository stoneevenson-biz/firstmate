#!/usr/bin/env bash
# The net that keeps the suites off the captain's live multiplexers.
#
# WHY THIS EXISTS. Both guards were added after the accident they prevent had
# already happened: test runs reached the real herdr server and left stray
# `design-home`, `spawn-proj` and `alpha` workspaces behind, and an early cut of
# gate h3 drove the real tmux server and left `firstmate:fm-fallback-t8` in the
# captain's live session. Those were creates - clutter someone notices and
# tidies. The tmux half guards something that does not come back: the cutover
# deliberately keeps the drain paths open, so `tmux kill-window` is a live call
# site, and the panes it can close are exactly the pre-cutover crewmates that may
# still be holding unlanded commits.
#
# A guard nothing exercises is a guard that rots. What is gated here:
#   * sourcing tests/lib.sh puts a refusing `herdr` AND a refusing `tmux` first
#     on PATH, so a suite that forgot to fake one fails loudly instead of
#     silently touching the fleet
#   * each opt-out is INDEPENDENT - a gate that needs the real herdr does not
#     thereby get the real tmux, and vice versa
#   * the opt-in is not a blank cheque: the real tmux is reached through a guard
#     that refuses a destructive verb aimed outside the throwaway session the
#     suite declared, and refuses it outright when none is declared
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/denybin/live-tmux/tmux"

# Run a snippet in a fresh bash that sources tests/lib.sh, with the named
# opt-ins pre-set. A subshell would inherit this file's own already-shimmed
# PATH, which would prove nothing about what sourcing does.
in_fresh() {  # <env-assignments...> -- <snippet>
  local envs=() snippet
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  snippet=$1
  env -u FM_TEST_ALLOW_LIVE_HERDR -u FM_TEST_ALLOW_LIVE_TMUX \
      -u FM_TEST_LIVE_TMUX_SESSION "${envs[@]}" \
      bash -c '. "$1/tests/lib.sh" >/dev/null 2>&1; shift; eval "$@"' \
      _ "$ROOT" "$snippet" 2>&1
}

# --- the default: neither binary is reachable -------------------------------

test_a_forgetful_suite_cannot_reach_either_binary() {
  local out rc=0
  out=$(in_fresh -- 'herdr session list') || rc=$?
  expect_code 97 "$rc" "a suite that did not fake herdr reached something other than the refusal"
  assert_contains "$out" "REAL herdr binary" "the herdr refusal does not say what was reached"
  assert_contains "$out" "fm_herdr_fake_server" "the herdr refusal does not say how to fake it"

  rc=0
  out=$(in_fresh -- 'tmux list-sessions') || rc=$?
  expect_code 97 "$rc" "a suite that did not fake tmux reached the REAL tmux server"
  assert_contains "$out" "REAL tmux binary" "the tmux refusal does not say what was reached"
  assert_contains "$out" "fm_herdr_fake_tmux" "the tmux refusal does not say how to fake it"
  assert_contains "$out" "unlanded commits" "the tmux refusal does not say why a kill is the dangerous one"
  pass "hermeticity: sourcing lib.sh denies BOTH live multiplexers, loudly and greppably"
}

# The two opt-outs are separate on purpose: a gate driving the real herdr binary
# has no business reaching real tmux. One flag opening both would quietly hand
# every live herdr gate a live `tmux kill-window`.
test_the_two_opt_outs_are_independent() {
  local out rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_HERDR=1 -- 'tmux list-sessions') || rc=$?
  expect_code 97 "$rc" "the herdr opt-out also handed the suite a live tmux"
  assert_contains "$out" "REAL tmux binary" "the tmux refusal did not fire under the herdr opt-out"

  rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 -- 'herdr session list') || rc=$?
  expect_code 97 "$rc" "the tmux opt-out also handed the suite a live herdr"
  assert_contains "$out" "REAL herdr binary" "the herdr refusal did not fire under the tmux opt-out"
  pass "hermeticity: each opt-out withholds only its own binary"
}

# --- the opt-in is guarded, not blank ---------------------------------------

test_opting_in_still_routes_through_the_guard() {
  local out
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 -- 'command -v tmux')
  [ "$out" = "$GUARD" ] \
    || fail "the tmux opt-in reached '$out', not the guard at '$GUARD'"
  pass "hermeticity: the tmux opt-in reaches the real binary through the guard"
}

test_a_kill_outside_the_declared_session_is_refused() {
  local out rc=0
  out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
        "$GUARD" kill-window -t firstmate:fm-drainer 2>&1) || rc=$?
  expect_code 97 "$rc" "a kill aimed at the fleet's own session was allowed through"
  assert_contains "$out" "firstmate:fm-drainer" "the refusal does not name the target it refused"
  assert_contains "$out" "fmtest-throwaway" "the refusal does not name the session that would be allowed"
  pass "hermeticity: a destructive verb outside the declared session is refused"
}

# Fail closed: no declared session must not mean "aim it at whatever is current".
test_a_kill_with_no_declared_session_is_refused() {
  local out rc=0
  out=$(env -u FM_TEST_LIVE_TMUX_SESSION \
        "$GUARD" kill-session -t whatever 2>&1) || rc=$?
  expect_code 97 "$rc" "a kill was allowed with no throwaway session declared"
  assert_contains "$out" "FM_TEST_LIVE_TMUX_SESSION" "the refusal does not say what to declare"

  rc=0
  out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
        "$GUARD" kill-server 2>&1) || rc=$?
  expect_code 97 "$rc" "kill-server was allowed; it can never be scoped to one session"

  # tmux's -a inverts the kill: `-a -t X` kills everything EXCEPT X. Scoping the
  # -t target is backwards there - a correctly declared throwaway session would
  # spare itself and take the fleet's with it - so it must be refused outright,
  # including in the combined `-at X` form.
  local form
  for form in "-a -t fmtest-throwaway" "-at fmtest-throwaway"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION=fmtest-throwaway \
          "$GUARD" kill-session $form 2>&1) || rc=$?
    expect_code 97 "$rc" "an inverted kill ('$form') was allowed through by scoping its -t target"
    assert_contains "$out" "ALL BUT the target" "the refusal does not say why -t cannot scope an inverted kill"
  done
  pass "hermeticity: an unscopeable, inverted or undeclared kill is refused, not aimed at the current session"
}

# The guard reads the same argv twice - once for the -t target, once for the
# inverting -a - and the two readings have to agree about what an argument IS.
# `-t` carries a VALUE, so `-tbar` is a target, not a flag bundle; a scan that
# only asks "does this contain an a" reads it as -a and refuses a correctly
# scoped kill, which fails closed but for a reason that is a lie. And a kill
# with no flags at all must reach the refusal rather than dying on an
# out-of-range index under `set -u`, which would abort the guard before it ever
# decided anything.
#
# Both verdicts are read WITHOUT a live tmux: pointing PATH at nothing means an
# allowed verb stops at the guard's own "no real tmux binary" report, which is
# proof it got past the scoping check with no live server involved.
test_the_two_argv_readings_agree() {
  local out rc form ses argv
  # "<declared session>|<argv>" - the -t value is the target in every allowed
  # row, including `-ta`, where tmux reads the "a" as -t's value and not as -a.
  local -a allowed=("fmthrow|kill-session -tfmthrow" \
                    "fmthrow|kill-session -t fmthrow" \
                    "fmthrow|kill-window -tfmthrow:fm-drainer" \
                    "a|kill-session -ta")
  local -a refused=("kill-session -at fmthrow" \
                    "kill-session -abc" \
                    "kill-session")
  for form in "${allowed[@]}"; do
    ses=${form%%|*}; argv=${form#*|}; rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION="$ses" PATH=/nonexistent-fm-test \
          "$BASH" "$GUARD" $argv 2>&1) || rc=$?
    assert_contains "$out" "no real tmux binary" \
      "the guard refused '$argv', which is scoped to the declared session '$ses'"
  done
  for argv in "${refused[@]}"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(FM_TEST_LIVE_TMUX_SESSION=fmthrow PATH=/nonexistent-fm-test \
          "$BASH" "$GUARD" $argv 2>&1) || rc=$?
    expect_code 97 "$rc" "'$argv' did not reach a refusal (the guard aborted or allowed it)"
    assert_contains "$out" "refusing a destructive tmux verb" \
      "'$argv' failed without the guard's own refusal"
  done
  pass "hermeticity: the -t target and the inverting -a are read from one argv, consistently"
}

# The guard must not become a second deny shim: a read-only verb, and a kill
# INSIDE the declared session, both have to reach the real binary. Run through
# in_fresh with the opt-in set, because that is the only PATH where the guard
# CAN reach it - this file itself carries the deny shim, by design.
test_the_guard_passes_scoped_and_harmless_verbs_through() {
  local ses="fmherm-$$" out rc=0 realpath_ real=
  # The skip check must ask about the REAL binary, not this file's deny shim, so
  # it searches a PATH with every denybin entry dropped rather than assuming
  # which one sourcing lib.sh happened to put first.
  realpath_=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/tests/denybin/' | paste -sd: -)
  real=$(PATH="$realpath_" command -v tmux 2>/dev/null || true)
  [ -n "$real" ] || {
    pass "hermeticity: pass-through (skipped: no tmux installed)"
    return 0
  }
  # Nothing below may outlive this test; the guard permits a kill in $ses.
  # shellcheck disable=SC2064
  trap "FM_TEST_LIVE_TMUX_SESSION='$ses' '$GUARD' kill-session -t '$ses' 2>/dev/null || true" RETURN

  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 FM_TEST_LIVE_TMUX_SESSION="$ses" \
        -- 'tmux -V') || rc=$?
  expect_code 0 "$rc" "the guard refused a harmless read-only verb"
  assert_contains "$out" "tmux" "the guard did not reach the real binary for a read-only verb"

  rc=0
  out=$(in_fresh FM_TEST_ALLOW_LIVE_TMUX=1 FM_TEST_LIVE_TMUX_SESSION="$ses" \
        -- "tmux new-session -d -s '$ses' && tmux kill-session -t '$ses'") || rc=$?
  if [ "$rc" = 97 ]; then
    fail "the guard refused a kill INSIDE the suite's own declared session"$'\n'"$out"
  fi
  [ "$rc" = 0 ] || {
    # A machine with no usable terminal for new-session cannot prove this half.
    pass "hermeticity: in-session kill (skipped: tmux new-session unavailable here)"
    return 0
  }
  pass "hermeticity: the guard passes read-only verbs and in-session kills through"
}

# Sitting first on PATH, the guard makes `command -v tmux` succeed. A suite
# probing for tmux would then be told it is installed and fail on an empty exec
# with nothing to read - the shape of a live half that "ran" and proved nothing.
test_an_absent_real_binary_is_reported_not_execed() {
  local dir out rc=0
  dir=$(fm_test_tmproot fm-herm-nobin)
  # Invoked through an ABSOLUTE interpreter, so an empty PATH hides every tmux
  # without also hiding the shell that has to run the guard in the first place.
  out=$(PATH="$dir" "$BASH" "$GUARD" -V 2>&1) || rc=$?
  expect_code 97 "$rc" "the guard exec'd nothing instead of reporting an absent tmux"
  assert_contains "$out" "no real tmux binary" "the guard does not say the binary is missing"
  assert_contains "$out" "did not silently pass" "the guard does not say what the silence would have meant"
  pass "hermeticity: an absent real tmux is reported, not exec'd as an empty command"
}

test_a_forgetful_suite_cannot_reach_either_binary
test_the_two_opt_outs_are_independent
test_opting_in_still_routes_through_the_guard
test_an_absent_real_binary_is_reported_not_execed
test_a_kill_outside_the_declared_session_is_refused
test_a_kill_with_no_declared_session_is_refused
test_the_two_argv_readings_agree
test_the_guard_passes_scoped_and_harmless_verbs_through
