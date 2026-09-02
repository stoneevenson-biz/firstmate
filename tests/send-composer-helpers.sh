#!/usr/bin/env bash
# send-composer-helpers.sh - the two composer rows a LIVE claude pane actually
# renders, and a fake tmux that serves them.
#
# WHY THE BYTES ARE VERBATIM. The suites that came before this one built their
# composer fixtures out of ASCII spaces, because that is what a person writing a
# fixture types. A real Claude Code pane does not: it pads its composer with
# U+00A0 NO-BREAK SPACE. A fixture written with ASCII spaces cannot exhibit the
# bug, which is why the existing suite stayed green through the whole incident.
#
# So these two rows are transcribed from `tmux capture-pane -e` against a real
# `claude` v2.1.258 pane on 2026-09-02, byte for byte:
#
#   empty composer:  342 235 257 302 240               -> U+276F U+00A0
#   typed composer:  342 235 257 302 240 m e r g e ...  -> U+276F U+00A0 "merge it"
#
# They differ by exactly one thing: whether real typed text is present. That is
# the control the two gates turn on. A "fix" that reported the first as delivered
# by loosening the detector would report the second as delivered too, and the
# swallowed-Enter gate exists to catch precisely that.
#
# WHY THE LOCALE IS PINNED. The bug is not that the bytes are unusual, it is that
# `[[:space:]]` in the detector's trim is LOCALE-DEPENDENT. Under a UTF-8 locale
# bash matches U+00A0 and everything works; under LC_ALL=C or LC_ALL=POSIX it
# matches ASCII only, the padding survives, and an EMPTY composer classifies as
# `pending`. A suite that ran in whatever locale the machine happened to have
# would therefore pass or fail by accident - and would have passed, unfixed, on
# this developer's machine. So every classification here is asserted across
# fm_composer_locales(), and the property under test is that the answer is the
# SAME in all of them.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The steer used throughout: an authorization, the class of message where a false
# "not delivered" invites a duplicate send and the agent acts twice.
FM_COMPOSER_STEER='merge it'

# fm_composer_row_empty: the cursor row of a live claude pane with NOTHING typed.
fm_composer_row_empty() { printf '\342\235\257\302\240\n'; }

# fm_composer_row_typed: the same pane with FM_COMPOSER_STEER sitting unsubmitted.
fm_composer_row_typed() { printf '\342\235\257\302\240%s\n' "$FM_COMPOSER_STEER"; }

# fm_make_composer_tmux <dir> <mode> -> echoes a fakebin dir holding a `tmux`
# that models one pane, where <mode> is:
#
#   lands     - Enter submits: the first `send-keys ... Enter` clears the composer
#               to the empty row, as a harness that took the prompt does.
#   swallowed - Enter is eaten: the composer keeps the typed row forever, which is
#               the ONLY state that may be reported as a steer that did not land.
#
# It records every Enter in <dir>/enters, so a test can prove the submit path
# actually retried rather than giving up, and every literal `send-keys -l` payload
# in <dir>/typed, so a test can prove the text was typed ONCE - retyping a steer
# whose Enter was swallowed would duplicate it in the composer.
#
# capture-pane honours -e the way tmux does: with it the styled row, without it
# the same row with SGR sequences removed (these fixtures carry no SGR, so the two
# coincide). cursor_y is a fixed valid row: this suite is about what the row
# CONTAINS, not about which row is read.
fm_make_composer_tmux() {  # <dir> <mode>
  local dir=$1 mode=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  : > "$dir/enters"
  : > "$dir/typed"
  : > "$dir/submitted"
  printf '%s\n' "$mode" > "$dir/mode"
  fm_composer_row_empty > "$dir/row-empty"
  fm_composer_row_typed > "$dir/row-typed"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
DIR=$FM_COMPOSER_DIR
case "${1:-}" in
  send-keys)
    literal=0
    for a in "$@"; do [ "$a" = "-l" ] && literal=1; done
    for last; do :; done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$last" >> "$DIR/typed"
    elif [ "$last" = Enter ]; then
      printf 'Enter\n' >> "$DIR/enters"
      [ "$(cat "$DIR/mode")" = lands ] && printf 'yes\n' > "$DIR/submitted"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -s "$DIR/submitted" ]; then cat "$DIR/row-empty"; else cat "$DIR/row-typed"; fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# fm_composer_locales: the locales every classification below is asserted across.
# C and POSIX are guaranteed to exist and are the two that BREAK the trim, so the
# gate is meaningful on any machine; a UTF-8 locale is added when the machine has
# one, which is the case that used to pass by luck. The invariant is that the
# classification does not differ between them.
fm_composer_locales() {
  printf 'C\nPOSIX\n'
  local utf8
  utf8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.(utf-?8)$' | head -1)
  [ -n "$utf8" ] && printf '%s\n' "$utf8"
  return 0
}

# fm_composer_state_in <locale> <fakebin> <dir> - classify the fake pane's cursor
# row with the detector running under <locale>. A fresh bash is used on purpose:
# the trim's behaviour is fixed when bash parses the locale, so setting LC_ALL in
# this shell after the fact would prove nothing.
fm_composer_state_in() {  # <locale> <fakebin> <dir>
  env LC_ALL="$1" PATH="$2:$PATH" FM_COMPOSER_DIR="$3" \
    bash -c '. "$0"/bin/fm-tmux-lib.sh; fm_tmux_composer_state fakepane' "$ROOT"
}

# fm_run_send <locale> <fakebin> <dir> <home> <target> <text...> - run bin/fm-send.sh
# against the fake pane, echoing its stderr; the caller reads $? for the exit
# code. FM_ROOT_OVERRIDE and FM_HOME point at a throwaway home so fm-guard stays
# quiet and the helm claim never reaches a real one. FM_SEND_SETTLE=0 removes the
# post-submit pause, which this suite is not about.
fm_run_send() {  # <locale> <fakebin> <dir> <home> <target> <text...>
  local loc=$1 fb=$2 dir=$3 home=$4; shift 4
  mkdir -p "$home/state"
  env LC_ALL="$loc" PATH="$fb:$PATH" FM_COMPOSER_DIR="$dir" \
      FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
      "$ROOT/bin/fm-send.sh" "$@" 2>&1 >/dev/null
}
