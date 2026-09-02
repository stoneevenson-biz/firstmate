#!/usr/bin/env bash
# gate-t4-swallowed-enter-still-refused
#
# THIS IS THE GATE THAT MATTERS. Its twin,
# gate-t4-landed-steer-not-reported-swallowed, fixes a false negative; the cheap
# way to make a false negative disappear is to report success unconditionally,
# and that trade is strictly worse than the bug. A false negative is annoying: a
# supervisor re-sends a steer that already landed. A false POSITIVE is the
# failure the whole verified-submit mechanism exists to prevent - firstmate is
# told an instruction reached a crewmate when it never did, and then supervises a
# crewmate that was never steered.
#
# So this suite asserts the direction that must survive the fix: when the Enter is
# genuinely eaten and the steer is STILL SITTING in the composer, fm-send must say
# so and exit non-zero.
#
# The control is deliberate. The fixture here is the SAME live-claude composer row
# as the landed gate, padded with the same U+00A0, asserted across the same
# locales, and differing only by the presence of real typed text. Any change that
# made an empty claude composer read as delivered by weakening the detector -
# rather than by seeing the padding for the blank it is - would make this one read
# as delivered too, and this gate goes red.
set -u

# shellcheck source=tests/send-composer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/send-composer-helpers.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-t4-swallowed)

test_typed_claude_composer_still_reads_pending() {
  local dir fb loc state seen=0
  dir="$TMP_ROOT/detector"; mkdir -p "$dir"
  fb=$(fm_make_composer_tmux "$dir" swallowed)
  while read -r loc; do
    [ -n "$loc" ] || continue
    seen=$((seen + 1))
    state=$(fm_composer_state_in "$loc" "$fb" "$dir")
    [ "$state" = pending ] \
      || fail "under LC_ALL=$loc a claude composer still holding '$FM_COMPOSER_STEER' read as '$state', not pending"
  done <<EOF
$(fm_composer_locales)
EOF
  [ "$seen" -ge 2 ] || fail "the locale matrix collapsed to $seen entries; it must cover at least C and POSIX"
  pass "detector: real typed text in a U+00A0-padded composer is pending in all $seen locales"
}

test_submit_core_verdict_is_pending_when_enter_is_eaten() {
  local dir fb verdict enters loc
  while read -r loc; do
    [ -n "$loc" ] || continue
    dir="$TMP_ROOT/core-$loc"; mkdir -p "$dir"
    fb=$(fm_make_composer_tmux "$dir" swallowed)
    verdict=$(fm_composer_bash "$loc" "$fb" "$dir" "$FM_COMPOSER_PROBE_SUBMIT")
    [ "$verdict" = pending ] \
      || fail "under LC_ALL=$loc the submit core called a swallowed Enter '$verdict'; expected pending"
    # It must have actually tried: a verdict reached without retrying Enter would
    # be an opinion, not an observation.
    enters=$(wc -l < "$dir/enters" | tr -d ' ')
    [ "$enters" = 3 ] || fail "submit core sent $enters Enters under LC_ALL=$loc; expected 3 retries"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "submit core: a swallowed Enter verdicts pending after retrying Enter, in every locale"
}

test_fm_send_still_fails_on_a_swallowed_enter() {
  local dir fb err rc typed loc
  while read -r loc; do
    [ -n "$loc" ] || continue
    dir="$TMP_ROOT/send-$loc"; mkdir -p "$dir"
    fb=$(fm_make_composer_tmux "$dir" swallowed)
    err=$(FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.05 \
          fm_run_send "$loc" "$fb" "$dir" "$dir/home" "sess:win" "$FM_COMPOSER_STEER"); rc=$?
    expect_code 1 "$rc" "under LC_ALL=$loc fm-send must exit non-zero when the Enter was swallowed"
    assert_contains "$err" "Enter swallowed" \
      "under LC_ALL=$loc fm-send did not name the swallowed Enter, so the operator learns nothing"
    # Never retyped: the steer is already in the composer, and a second copy would
    # be sent the moment the harness finally accepts an Enter.
    typed=$(wc -l < "$dir/typed" | tr -d ' ')
    [ "$typed" = 1 ] || fail "fm-send typed the steer $typed times; must type once"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "fm-send: a genuinely swallowed Enter still exits non-zero and says why, in every locale"
}

test_a_composer_of_only_padding_is_not_treated_as_text() {
  local dir fb state loc
  # The narrow reading of the fix: padding is blank, so a row of nothing but
  # padding is an empty composer. This is the ONLY way the fold could ever report
  # a lost steer as delivered - a steer made entirely of invisible blanks, which
  # is not a steer - and it is pinned here so the boundary is stated rather than
  # assumed. One real character among the padding flips it straight back.
  dir="$TMP_ROOT/padding"; mkdir -p "$dir"
  fb=$(fm_make_composer_tmux "$dir" swallowed)
  while read -r loc; do
    [ -n "$loc" ] || continue
    printf '\302\240\342\200\257\343\200\200\n' > "$dir/row-typed"
    state=$(fm_composer_state_in "$loc" "$fb" "$dir")
    [ "$state" = empty ] || fail "under LC_ALL=$loc a row of pure padding read as '$state', not empty"
    printf '\302\240x\342\200\257\n' > "$dir/row-typed"
    state=$(fm_composer_state_in "$loc" "$fb" "$dir")
    [ "$state" = pending ] || fail "under LC_ALL=$loc one real character among padding read as '$state', not pending"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "boundary: pure padding is empty, and one real character is pending, in every locale"
}

test_typed_claude_composer_still_reads_pending
test_submit_core_verdict_is_pending_when_enter_is_eaten
test_fm_send_still_fails_on_a_swallowed_enter
test_a_composer_of_only_padding_is_not_treated_as_text
