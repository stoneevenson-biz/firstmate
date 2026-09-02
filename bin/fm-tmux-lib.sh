#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e), drops dim/faint (SGR 2) runs, and decides on
# what is left, so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that dims placeholder/ghost text benefits.
#
# Composer padding (incident send-false-negative): claude pads its EMPTY composer
# with U+00A0 NO-BREAK SPACE. `[[:space:]]` is locale-dependent, so under LC_ALL=C
# the padding survived the trim and an empty composer read as pending input - which
# made fm-send report "Enter swallowed" for steers that had landed, in some
# sessions and not others. The reader now folds non-ASCII blanks onto ASCII space
# before trimming, so the classification is the same in every locale. See
# docs/specs/2026-09-02-composer-blank-padding.md.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working...".
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'

# Non-ASCII blanks a harness pads its composer with. THE DEFECT THIS EXISTS FOR
# (incident send-false-negative, observed 2026-08-28): a live Claude Code pane
# renders its EMPTY composer as U+276F followed by U+00A0 NO-BREAK SPACE -
# captured verbatim from `tmux capture-pane -e` against claude v2.1.258 on
# 2026-09-02 as the five bytes \342\235\257\302\240.
#
# `[[:space:]]` in the trim below is LOCALE-DEPENDENT, which is the part that
# bites. Under a UTF-8 locale bash matches U+00A0 and the row trims down to a
# bare prompt glyph, so the composer reads `empty` and everything works. Under
# LC_ALL=C or LC_ALL=POSIX - and under bash 3.2 with no locale set at all - it
# matches ASCII only, the padding SURVIVES, the row `❯<NBSP>` fails the
# bare-prompt-glyph case, matches no busy footer, and classifies as `pending`.
#
# So fm-send reported "Enter swallowed; text left in composer" for a steer that
# had landed, in some sessions and not others, with nothing in the pane to
# explain the difference. Verified end to end against a live claude pane: with
# LC_ALL=C the submit core verdicts `pending` while the agent is visibly working
# on the steer it just accepted. The same misread makes every idle claude pane
# read as holding pending input, which is incident afk-invx-i5 returning through
# a different glyph.
#
# This file states in its own header that it is byte-wise and locale-independent.
# The trim quietly was not, so the padding is folded onto ASCII space here, ahead
# of it, and the claim becomes true.
#
# Folding is a NARROWING, not a loosening: it can only turn invisible padding
# into the blank it already is. The one way it could report a lost steer as
# delivered is a steer made ENTIRELY of these characters, which is not a steer.
# Real text on the row still classifies as pending, which is the direction that
# must never regress.
#
# Written as printf octal escapes so this file stays plain ASCII - an invisible
# NBSP sitting in source is unreviewable - and needs no \u escape, which bash 3.2
# does not have.
FM_TMUX_BLANK_CHARS=(
  "$(printf '\302\240')"      # U+00A0  NO-BREAK SPACE (claude's composer padding)
  "$(printf '\342\200\202')"  # U+2002  EN SPACE
  "$(printf '\342\200\203')"  # U+2003  EM SPACE
  "$(printf '\342\200\207')"  # U+2007  FIGURE SPACE
  "$(printf '\342\200\211')"  # U+2009  THIN SPACE
  "$(printf '\342\200\213')"  # U+200B  ZERO WIDTH SPACE
  "$(printf '\342\200\257')"  # U+202F  NARROW NO-BREAK SPACE
  "$(printf '\343\200\200')"  # U+3000  IDEOGRAPHIC SPACE
  "$(printf '\357\273\277')"  # U+FEFF  ZERO WIDTH NO-BREAK SPACE
)

# fm_tmux_fold_blanks: replace every non-ASCII blank above with an ASCII space,
# so the locale-dependent trim that follows can see it in every locale. Reads one string as
# $1 and prints the folded string; pure, no tmux, no locale dependence.
fm_tmux_fold_blanks() {  # <string>
  local s=${1-} b
  for b in "${FM_TMUX_BLANK_CHARS[@]}"; do
    s=${s//"$b"/ }
  done
  printf '%s' "$s"
}

# fm_tmux_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one captured
# composer line, then drop any remaining escape sequences, leaving only the plain,
# normal-intensity text, the text a human actually typed. Dim/faint runs are
# ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion) that
# fills an otherwise-empty composer and must never read as pending input. Reads the
# styled line on stdin (from `tmux capture-pane -e`) and prints plain text on
# stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and dim runs
# alike pass through or drop intact without locale-dependent character classes.
# A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run; codes are processed
# left to right within a sequence so "ESC[0;2m" (reset then dim) reads as dim.
fm_tmux_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, a busy footer, or only dim
#             ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error). The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E), then run through fm_tmux_strip_ghost so dim/faint
# ghost text drops out before classification, then through fm_tmux_fold_blanks so
# the harness's non-ASCII composer padding (U+00A0 and friends) becomes the blank
# it already is rather than surviving the locale-dependent trim as typed text.
# The styled capture is internal only, never surfaced.
# The detector then strips the harness's box-drawing composer
# borders ("│ … │", heavy "┃", or a plain ASCII "|") using literal-string
# substitution (bash 3.2 safe, locale-independent — no \u escapes, no multibyte
# character classes), and asks whether anything real is left.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw line stripped
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  line=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  # Fold the harness's non-ASCII composer padding onto ASCII space BEFORE the
  # trim below, whose [[:space:]] is locale-dependent and sees ASCII only under
  # LC_ALL=C. Without this a live claude pane's empty composer (`❯` + U+00A0)
  # reads as pending input in exactly the sessions that run in the C locale.
  line=$(fm_tmux_fold_blanks "$line")
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # Nothing left inside the box = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the cursor line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
# fm_tmux_wait_shell_ready <target> [timeout-seconds] -> 0 ready, 1 not ready
#
# Proves the pane's SHELL is accepting command lines before anything important
# is typed into it.
#
# fm-spawn used to infer readiness from pane_current_path changing, which only
# proves `treehouse get` chdir'd - it says nothing about whether the shell has
# returned to a prompt. When it had not, the whole launch string was typed into
# a mid-command shell as raw text. Observed 2026-08-26: the cellarsky-sm and
# hermes-jarvis-sm secondmates were both found as bare zsh prompts, their
# `claude --dangerously-skip-permissions "<charter>"` line having died on
# `zsh: parse error near \`do'`. They had never started.
#
# The probe is a bounded echo round-trip: send a unique marker through the
# shell and wait to see it rendered back on a line of its own. Seeing it is
# positive proof the shell read a command line, ran it, and printed a result -
# an acknowledgment channel that bare `send-keys` does not have. A probe that
# lands in a busy shell is a harmless short printf, unlike a multi-KB launch
# string. Only the OUTPUT line matches (-x, whole line); the echoed command
# line containing the marker does not.
fm_tmux_wait_shell_ready() {  # <target> [timeout]
  local target=$1 timeout=${2:-${FM_SHELL_READY_TIMEOUT:-20}}
  local poll=${FM_SHELL_READY_POLL:-0.2} marker deadline now waited
  marker="fmready$$$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -cd '0-9')"
  now=$(date +%s); deadline=$((now + timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    tmux send-keys -t "$target" -l "printf '%s\\n' $marker" 2>/dev/null || return 1
    tmux send-keys -t "$target" Enter 2>/dev/null || return 1
    waited=0
    while [ "$waited" -lt 10 ]; do
      sleep "$poll"
      waited=$((waited + 1))
      if tmux capture-pane -p -t "$target" 2>/dev/null | grep -qx "$marker"; then
        return 0
      fi
    done
  done
  return 1
}

# fm_tmux_launch_failed <target> -> 0 if the pane shows a shell error
#
# Post-launch verification. If the launch string reached the shell as text
# instead of starting the agent, the shell says so - and firstmate should fail
# loudly rather than record a meta for a pane that holds nothing.
fm_tmux_launch_failed() {  # <target>
  local target=$1 tail
  tail=$(tmux capture-pane -p -t "$target" -S -15 2>/dev/null) || return 1
  printf '%s' "$tail" | grep -qiE 'parse error|command not found|syntax error near|no such file or directory'
}

fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
