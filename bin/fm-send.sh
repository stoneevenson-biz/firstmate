#!/usr/bin/env bash
# Send one line of literal text to a crewmate window, then Enter.
# Usage: fm-send.sh <window> <text...>
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or an explicit opaque multiplexer target
#   (session:window under tmux, a pane id under herdr). A RAW target carries no
#   meta, so it is read as a tmux session:window unless FM_MUX says otherwise.
# Special keys instead of text: fm-send.sh <window> --key Escape   (or Enter, C-c, ...)
#
# Delivery goes through the multiplexer seam (bin/fm-mux-lib.sh), and through
# the driver that MINTED the target - recorded as mux= in the task's meta by
# fm-spawn - never whichever driver happens to resolve at this moment.
#
# The two drivers reach the same guarantee by different roads, and the gap
# between them is the whole reason the seam exists:
#   tmux   has no acknowledgment channel, so the text is typed once and Enter is
#          retried until the composer clears (the verified-submit dance below).
#   herdr  classifies agent lifecycle natively and `agent prompt --wait` returns
#          only once the agent has actually consumed the prompt. One acknowledged
#          call replaces the whole dance - and a blocked agent sitting at an
#          approval dialog is REFUSED rather than typed over.
#
# The tmux path's verified submission, unchanged: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (the text is still sitting in the composer after
# all retries), fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction (incident afk-invx-i5).
# The composer/submit logic is shared with the away-mode daemon via
# bin/fm-tmux-lib.sh. Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: a cleared composer only proves the text was
# submitted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-mux-lib.sh
. "$SCRIPT_DIR/fm-mux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

fm_mux_resolve "$1" "$STATE" || exit 1
T=$FM_MUX_TARGET
DRV=$(fm_mux_driver)
shift

if [ "${1:-}" = "--key" ]; then
  fm_mux_send_key "$T" "$2"
elif [ "$DRV" != tmux ]; then
  # Acknowledged delivery. There is nothing to verify afterwards and nothing to
  # settle for: the call does not return until the agent has taken the prompt,
  # so the failure modes the tmux path has to infer are reported here directly.
  rc=0
  fm_mux_send "$T" "$*" || rc=$?
  case "$rc" in
    0) : ;;
    3) echo "error: $T is at an approval dialog; the steer was refused, not delivered" >&2; exit 1 ;;
    4)
      # Delivered, but the acknowledgment never came. Same lenient rule the tmux
      # path uses: only a POSITIVELY CONFIRMED swallow is an error. Reporting
      # failure here would make the caller re-send a steer that already landed.
      echo "warning: $T took the steer but did not acknowledge it; assuming delivered, not re-sending" >&2
      ;;
    *) echo "error: text not submitted to $T ($DRV delivery failed)" >&2; exit 1 ;;
  esac
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) settle=1.2 ;; *) settle=0.3 ;; esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Lenient: only a positively-confirmed swallow
  # (text still in the composer) is an error; an unreadable pane is assumed sent.
  verdict=$(fm_tmux_submit_core "$T" "$*" "$retries" "$sleep_s" "$settle")
  case "$verdict" in
    pending)
      echo "error: text not submitted to $T (Enter swallowed; text left in composer)" >&2
      exit 1
      ;;
    send-failed)
      echo "error: text not sent to $T (tmux send-keys failed)" >&2
      exit 1
      ;;
  esac
  # Submit landed (verdict was not pending/send-failed). The cleared composer only
  # proves the text was submitted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
