#!/usr/bin/env bash
# gate-t4-landed-steer-not-reported-swallowed
#
# A steer that LANDED must be reported as delivered.
#
# THE DEFECT THIS EXISTS FOR (incident send-false-negative, observed 2026-08-28):
# firstmate sent a merge authorization to fm-fmx-plat, fm-send reported "Enter
# swallowed; text left in composer", and the pane showed the prompt accepted with
# the agent already thinking. The steer had landed.
#
# The cause is a locale. A live Claude Code pane pads its EMPTY composer with
# U+00A0 NO-BREAK SPACE, so the cursor row reads `U+276F U+00A0`.
# fm_tmux_composer_state trims with `[[:space:]]`, whose meaning depends on the
# locale bash was started in: a UTF-8 locale matches U+00A0 and the row trims to a
# bare prompt glyph (empty, correct), while LC_ALL=C and LC_ALL=POSIX match ASCII
# only, the padding survives, the row fails the bare-prompt-glyph case, matches no
# busy footer, and falls through to `pending`. Same pane, same bytes, opposite
# verdict - which is why it looked intermittent and why nothing in the pane
# explained it. Verified against a live claude pane: under LC_ALL=C the submit
# core verdicts `pending` while the agent is visibly working on the steer it just
# accepted.
#
# A false failure is worse than it sounds. For an authorization it invites a
# duplicate send, and the agent acts twice; and a detector that cries wolf
# destroys the exact trust the verified-submit model exists to earn.
#
# This gate asserts the direction that was broken. Its twin,
# gate-t4-swallowed-enter-still-refused, asserts the direction that must NOT
# regress - together they are the pair, and neither is meaningful alone.
set -u

# shellcheck source=tests/send-composer-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/send-composer-helpers.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-t4-landed)

# --- the detector, on the exact bytes a live claude pane emits ---------------

test_empty_claude_composer_reads_empty_in_every_locale() {
  local dir fb loc state seen=0
  dir="$TMP_ROOT/detector"; mkdir -p "$dir"
  fb=$(fm_make_composer_tmux "$dir" lands)
  printf 'yes\n' > "$dir/submitted"   # the pane's post-submit, empty state
  while read -r loc; do
    [ -n "$loc" ] || continue
    seen=$((seen + 1))
    state=$(fm_composer_state_in "$loc" "$fb" "$dir")
    [ "$state" = empty ] \
      || fail "under LC_ALL=$loc a live claude pane's EMPTY composer (U+276F U+00A0) read as '$state', not empty"
  done <<EOF
$(fm_composer_locales)
EOF
  [ "$seen" -ge 2 ] || fail "the locale matrix collapsed to $seen entries; it must cover at least C and POSIX"
  pass "detector: an empty U+00A0-padded claude composer reads empty in all $seen locales"
}

test_fold_is_narrow_not_a_blanket_pass() {
  local out
  # The fold turns invisible padding into the blank it already is - and nothing
  # else. Real text on either side of it must survive intact, or the detector
  # would have been loosened into always-success.
  out=$(fm_tmux_fold_blanks "$(printf 'a\302\240b')")
  [ "$out" = "a b" ] || fail "fold mangled real text around the padding: '$out'"
  out=$(fm_tmux_fold_blanks "merge it")
  [ "$out" = "merge it" ] || fail "fold altered plain ASCII text: '$out'"
  out=$(fm_tmux_fold_blanks "$(printf '\302\240\342\200\257\343\200\200')")
  [ "$out" = "   " ] || fail "fold missed a non-ASCII blank: '$out'"
  pass "fold: non-ASCII blanks become spaces, and real text is untouched"
}

# --- the submit core ---------------------------------------------------------

test_submit_core_verdict_is_empty_when_enter_lands() {
  local dir fb verdict loc
  while read -r loc; do
    [ -n "$loc" ] || continue
    dir="$TMP_ROOT/core-$loc"; mkdir -p "$dir"
    fb=$(fm_make_composer_tmux "$dir" lands)
    verdict=$(fm_composer_bash "$loc" "$fb" "$dir" "$FM_COMPOSER_PROBE_SUBMIT")
    [ "$verdict" = empty ] \
      || fail "under LC_ALL=$loc the submit core called a landed steer '$verdict'; expected empty"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "submit core: a landed Enter into a claude pane verdicts empty in every locale"
}

# --- fm-send.sh, end to end --------------------------------------------------

test_fm_send_reports_success_for_a_landed_steer() {
  local dir fb err rc typed loc
  while read -r loc; do
    [ -n "$loc" ] || continue
    dir="$TMP_ROOT/send-$loc"; mkdir -p "$dir"
    fb=$(fm_make_composer_tmux "$dir" lands)
    err=$(fm_run_send "$loc" "$fb" "$dir" "$dir/home" "sess:win" "$FM_COMPOSER_STEER"); rc=$?
    expect_code 0 "$rc" "under LC_ALL=$loc fm-send must report a landed steer as delivered"
    assert_not_contains "$err" "Enter swallowed" \
      "under LC_ALL=$loc fm-send reported a landed steer as a swallowed Enter"
    # The text is typed exactly once, whatever the verdict: retyping would
    # duplicate a steer that is already sitting in the composer.
    typed=$(wc -l < "$dir/typed" | tr -d ' ')
    [ "$typed" = 1 ] || fail "fm-send typed the steer $typed times; must type once"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "fm-send: a landed steer exits 0 with no swallowed-Enter error, in every locale"
}

test_empty_composer_is_not_read_as_pending_input() {
  local dir fb loc rc
  # The same misread made the away-mode daemon see every idle claude pane as
  # holding pending input, which is what deferred 100% of escalations for 9.5
  # hours in afk-invx-i5. Same one detector, so the same fixture proves it.
  dir="$TMP_ROOT/idle"; mkdir -p "$dir"
  fb=$(fm_make_composer_tmux "$dir" lands)
  printf 'yes\n' > "$dir/submitted"
  while read -r loc; do
    [ -n "$loc" ] || continue
    rc=0
    fm_composer_bash "$loc" "$fb" "$dir" "$FM_COMPOSER_PROBE_PENDING" || rc=$?
    [ "$rc" != 0 ] \
      || fail "under LC_ALL=$loc an idle claude pane read as holding pending input (afk-invx-i5 class)"
  done <<EOF
$(fm_composer_locales)
EOF
  pass "an idle claude pane is not read as holding pending input, in any locale"
}

test_empty_claude_composer_reads_empty_in_every_locale
test_fold_is_narrow_not_a_blanket_pass
test_submit_core_verdict_is_empty_when_enter_lands
test_fm_send_reports_success_for_a_landed_steer
test_empty_composer_is_not_read_as_pending_input
