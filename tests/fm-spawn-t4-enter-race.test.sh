#!/usr/bin/env bash
# The launch Enter is accounted for.
# Usage: bash tests/fm-spawn-t4-enter-race.test.sh [<case>...]  (default: all)
# spec: docs/specs/2026-09-02-spawn-enter-gate.md
#
# THE INCIDENT (2026-08-28..09-02, repeatedly). Spawned panes were found sitting
# at an empty composer with the brief never submitted, and - the same defect,
# with a worse ending - crewmates were found dead with the trust dialog resting
# on `No, exit` and no claude process left. Firstmate hand-recovered these all
# week by pressing Down then Enter.
#
# WHY IT IS A SAFETY BUG AND NOT AN ANNOYANCE. The first dialog a fresh claude
# pane renders is the trust prompt, and its default option is `No, exit`. An
# Enter that reaches it does not merely fail to launch: it answers a safety
# dialog with its destructive default.
#
# ROOT CAUSE, in two halves that compound.
#   1. `herdr pane run` sends the text and the Enter in ONE unacknowledged call
#      - the binary says so itself. fm-spawn used it for the LAUNCH, so the
#      Enter went in whether or not the surface was ready to consume it.
#   2. `fm_herdr_wait_shell_ready` resent the SAME marker on every retry and
#      opened on the first sighting of it, so the echo that satisfied the gate
#      was not attributable to any particular probe. Probe 1's output opened the
#      gate while probes 2..N were still unconsumed keystrokes - Enters fm-spawn
#      had typed and could no longer account for. herdr routes keys to an agent
#      the moment it classifies one, so an unaccounted Enter is an Enter that
#      can be delivered somewhere other than the shell it was aimed at.
#
# THE PROPERTY THESE GATES PIN is stronger than "the brief got submitted": every
# Enter fm-spawn puts into a pane is accounted for, so none can be buffered into
# a dialog. Five properties, five gates, one case each - a single combined "the
# launch is safe" gate would have gone green the moment any one of them was
# fixed.
#
# Mutation (LEDGER_MUTATE=1): each case asserts the DEFECTIVE expectation - the
# behaviour of the code as it stood - which a correct implementation violates.
#
# All of it is hermetic over a fake herdr that models a real pty: keystrokes are
# QUEUED, a shell consumes them at its own pace, and whatever is still queued
# when the agent starts is inherited by the agent. No real pane is created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

MUTATE="${LEDGER_MUTATE:-0}"
TMP_ROOT=$(fm_test_tmproot fm-spawn-t4-enter-race)
PANE=wZ:p2
LAUNCH_LINE="FM_HOME=/home AGENTLAUNCH claude --dangerously-skip-permissions /data/x/brief.md"

# A fake herdr whose pane has an INPUT QUEUE, which is the whole point: a
# keystroke that has been sent is not the same as a keystroke that has been
# consumed, and every failure here lives in the gap between the two.
#
#   PTY_QUEUE      lines submitted and awaiting the shell
#   PTY_TEXT       the composing line: send-text put it there, no Enter yet
#   PTY_PANE       what the pane renders
#   PTY_AGENT      exists once the launch line has been consumed and exec'd
#   PTY_AGENT_IN   everything that reached the AGENT's input - the dialog's food
#   PTY_ENTERS     one line per submit, recording the queue depth at that moment
#   PTY_TICKS      observation counter; the shell runs on ticks, not on wall time
#   PTY_CONSUME_AFTER  ticks the shell stays busy before it reads anything
#   PTY_BUDGET     lines the shell consumes per tick (default 1: incremental)
#   PTY_ECHO       0 = the pane never echoes what was typed into it
#   PTY_AGENT_STATE  agent_status once an agent exists
make_pty_herdr() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS:-/dev/null}"

_agent_up() { [ -e "$PTY_AGENT" ]; }

# Submit one line. With an agent in the pane there IS no shell queue any more:
# the line goes to the agent, which is the delivery this whole suite exists to
# make impossible for an Enter fm-spawn did not account for.
_submit() {
  if _agent_up; then printf '%s\n' "$1" >> "$PTY_AGENT_IN"; return; fi
  printf '%s\n' "$1" >> "$PTY_QUEUE"
}

_depth() { wc -l < "$PTY_QUEUE" | tr -d ' '; }

_log_enter() { printf 'depth=%s target=%s\n' "$(_depth)" "$1" >> "$PTY_ENTERS"; }

# The shell reads. It reads nothing while it is busy, then at most PTY_BUDGET
# lines per observation - a shell that drains incrementally, which is the only
# way a queue can be non-empty at an interesting moment.
_tick() {
  local n b line rest
  n=$(cat "$PTY_TICKS" 2>/dev/null || echo 0)
  n=$((n + 1)); printf '%s' "$n" > "$PTY_TICKS"
  [ "$n" -gt "${PTY_CONSUME_AFTER:-0}" ] || return 0
  b=${PTY_BUDGET:-1}
  while [ "$b" -ne 0 ] && [ -s "$PTY_QUEUE" ]; do
    line=$(head -n 1 "$PTY_QUEUE")
    rest=$(tail -n +2 "$PTY_QUEUE"); printf '%s' "${rest:+$rest
}" > "$PTY_QUEUE"
    if _agent_up; then
      printf '%s\n' "$line" >> "$PTY_AGENT_IN"
    else
      case "$line" in
        *"${PTY_LAUNCH_MATCH:-AGENTLAUNCH}"*)
          : > "$PTY_AGENT"
          printf 'agent started\n' >> "$PTY_PANE"
          # EXEC INHERITANCE: whatever is still queued when the agent takes the
          # pane is read by the AGENT, not by the shell that was aimed at.
          if [ -s "$PTY_QUEUE" ]; then
            cat "$PTY_QUEUE" >> "$PTY_AGENT_IN"; : > "$PTY_QUEUE"
          fi ;;
        "printf '%s\n' "*) printf '%s\n' "${line##*\' }" >> "$PTY_PANE" ;;
        *) printf '$ %s\n' "$line" >> "$PTY_PANE" ;;
      esac
    fi
    b=$((b - 1))
  done
}

_agent_json() {
  printf '{"id":"cli:agent:get","result":{"agent":{"agent":"claude","agent_status":"%s","pane_id":"%s","tab_id":"wZ:t2","terminal_title":"blocked working idle done","terminal_title_stripped":"blocked working idle done","workspace_id":"wZ"},"type":"agent_info"}}\n' \
    "${PTY_AGENT_STATE:-idle}" "$3"
}

case "$1 $2" in
  "pane run")
    _log_enter pane
    _submit "$4"
    _tick
    printf '{"id":"cli:pane:run","result":{"type":"ok"}}\n' ;;
  "pane send-text")
    printf '%s' "$4" >> "$PTY_TEXT"
    [ "${PTY_ECHO:-1}" = 1 ] && printf '$ %s\n' "$4" >> "$PTY_PANE"
    printf '{"id":"cli:pane:send-text","result":{"type":"ok"}}\n' ;;
  "pane send-keys")
    _log_enter pane
    _submit "$(cat "$PTY_TEXT" 2>/dev/null)"
    : > "$PTY_TEXT"
    _tick
    printf '{"id":"cli:pane:send-keys","result":{"type":"ok"}}\n' ;;
  "agent send-keys")
    # herdr routes a key to the AGENT once it has classified one. A launch Enter
    # that came through here would be answering the dialog.
    if _agent_up; then
      _log_enter agent
      printf '%s\n' "key:$3" >> "$PTY_AGENT_IN"
      printf '{"id":"cli:agent:send-keys","result":{"type":"ok"}}\n'
      exit 0
    fi
    echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}' >&2
    exit 1 ;;
  "pane wait-output")
    _want=""; _prev=""
    for _a in "$@"; do
      [ "$_prev" = --match ] && _want=$_a
      _prev=$_a
    done
    _i=0
    while [ "$_i" -lt 40 ]; do
      _tick
      if grep -qF -- "$_want" "$PTY_PANE" 2>/dev/null; then
        printf '{"id":"cli:pane:wait-output","result":{"type":"ok"}}\n'; exit 0
      fi
      _i=$((_i + 1))
    done
    echo '{"error":{"code":"timeout","message":"no match"}}' >&2
    exit 1 ;;
  "pane read"|"agent read")
    _tick
    cat "$PTY_PANE" 2>/dev/null ;;
  "agent get")
    if _agent_up; then _agent_json "$@"; exit 0; fi
    echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}' >&2
    exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

FB=$(make_pty_herdr "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH

# A fresh pane per case: nothing here should ever depend on another case's
# leftovers, least of all a queue.
new_pane() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  PTY_QUEUE="$d/queue"; PTY_TEXT="$d/text"; PTY_PANE="$d/pane"
  PTY_AGENT="$d/agent"; PTY_AGENT_IN="$d/agent-in"; PTY_ENTERS="$d/enters"
  PTY_TICKS="$d/ticks"; CALLS="$d/calls"
  export PTY_QUEUE PTY_TEXT PTY_PANE PTY_AGENT PTY_AGENT_IN PTY_ENTERS PTY_TICKS CALLS
  : > "$PTY_QUEUE"; : > "$PTY_TEXT"; : > "$PTY_PANE"
  : > "$PTY_AGENT_IN"; : > "$PTY_ENTERS"; : > "$CALLS"
  printf '0' > "$PTY_TICKS"
  rm -f "$PTY_AGENT"
  PTY_CONSUME_AFTER=0; PTY_BUDGET=1; PTY_ECHO=1; PTY_AGENT_STATE=idle
  PTY_LAUNCH_MATCH=AGENTLAUNCH
  export PTY_CONSUME_AFTER PTY_BUDGET PTY_ECHO PTY_AGENT_STATE PTY_LAUNCH_MATCH
  FM_SHELL_READY_POLL=0.01; FM_SHELL_READY_TIMEOUT=20; FM_INPUT_DRAIN_TIMEOUT=10
  export FM_SHELL_READY_POLL FM_SHELL_READY_TIMEOUT FM_INPUT_DRAIN_TIMEOUT
}

count_calls() {  # <verb-prefix>
  grep -cF -- "$1" "$CALLS" 2>/dev/null || true
}

# --- gate-t4-launch-enter-waits-for-echo ------------------------------------
#
# No echo, no Enter. A pane that never shows the launch text has not proven it
# can consume anything, so the launch must end with NOTHING having been
# submitted - not with an Enter fired hopefully into it.
case_enter_waits_for_echo() {
  # THE CONTRAST FIRST, so this gate cannot go green by the launch primitive
  # simply not existing. Against the very same non-echoing pane, the one-call
  # path fm-spawn used to take puts an Enter straight in - which is both the
  # defect and the proof that the fake models the hazard rather than assuming it.
  new_pane enter-waits-blind
  PTY_ECHO=0; export PTY_ECHO
  fm_herdr_run "$PANE" "$LAUNCH_LINE" >/dev/null 2>&1 || true
  assert_grep "depth=" "$PTY_ENTERS" \
    "the fake pane accepted no Enter from the blind path, so this gate would prove nothing"

  command -v fm_herdr_launch_line >/dev/null 2>&1 \
    || fail "no gated launch primitive: the launch still sends text and Enter in one blind call"

  new_pane enter-waits
  PTY_ECHO=0; export PTY_ECHO   # the pane never renders what was typed
  local rc=0
  fm_herdr_launch_line "$PANE" "$LAUNCH_LINE" 200 >/dev/null 2>&1 || rc=$?

  if [ "$MUTATE" = 1 ]; then
    assert_grep "depth=" "$PTY_ENTERS" \
      "MUTATION: an Enter was expected to go in regardless of the echo"
    return 0
  fi
  [ "$rc" -ne 0 ] || fail "launch reported success against a pane that never echoed"
  [ -s "$PTY_ENTERS" ] && fail "an Enter was sent into a pane that never proved it could consume it"
  assert_absent "$PTY_AGENT" "an agent was started by a launch that was never submitted"
  pass "enter-waits-for-echo: no echo, no Enter - nothing was submitted"
}

# --- gate-t4-readiness-proves-the-queue-drained -----------------------------
#
# The readiness gate must prove the pane's input queue is EMPTY, not merely that
# a shell ran something. The race is constructed, not hoped for: the shell stays
# busy long enough for a second probe to go out, then consumes ONE line per
# observation, so there is a real window in which probe 1's marker is on screen
# and probe 2 is still an unconsumed keystroke.
case_readiness_proves_queue_drained() {
  new_pane readiness-drain
  PTY_CONSUME_AFTER=12; PTY_BUDGET=1; export PTY_CONSUME_AFTER PTY_BUDGET
  local rc=0 depth
  fm_herdr_wait_shell_ready "$PANE" 20 || rc=$?
  depth=$(wc -l < "$PTY_QUEUE" | tr -d ' ')

  if [ "$MUTATE" = 1 ]; then
    [ "$rc" = 0 ] && [ "$depth" -gt 0 ] && return 0
    fail "MUTATION: the gate was expected to open with keystrokes still queued"
  fi
  [ "$rc" = 0 ] || fail "readiness never opened against a shell that did drain"
  [ "$depth" = 0 ] || fail "readiness opened with $depth keystroke(s) still unconsumed in the pane"
  # And the drain sentinel is the terminal proof, sent exactly once.
  local before after
  before=$(count_calls 'pane run')
  fm_herdr_input_drained "$PANE" 10 || fail "the drain sentinel never round-tripped on a ready shell"
  after=$(count_calls 'pane run')
  [ "$((after - before))" = 1 ] || fail "the drain sentinel was sent $((after - before)) times; it must be sent once and never resent"
  [ "$(wc -l < "$PTY_QUEUE" | tr -d ' ')" = 0 ] || fail "the drain sentinel returned with the queue still non-empty"
  pass "readiness-proves-queue-drained: the gate opens only on an empty input queue"
}

# --- gate-t4-launch-enter-never-reaches-the-agent ---------------------------
#
# Two ways the launch Enter could become an ANSWER, both closed here: it must be
# aimed at the pane's shell rather than at an agent (herdr routes to an agent as
# soon as it has classified one), and it must not be pressed at all while a live
# dialog is holding the pane.
case_enter_never_reaches_agent() {
  new_pane enter-routing
  : > "$PTY_AGENT"                       # an agent is already in the pane
  PTY_AGENT_STATE=blocked; export PTY_AGENT_STATE   # holding a live dialog
  local rc=0
  fm_herdr_launch_line "$PANE" "$LAUNCH_LINE" 200 >/dev/null 2>&1 || rc=$?

  if [ "$MUTATE" = 1 ]; then
    [ -s "$PTY_AGENT_IN" ] && return 0
    fail "MUTATION: the Enter was expected to reach the agent's dialog"
  fi
  [ "$rc" -ne 0 ] || fail "launch reported success into a pane holding a live dialog"
  [ -s "$PTY_AGENT_IN" ] && fail "a keystroke reached the agent that was holding a dialog"
  assert_no_grep "agent send-keys" "$CALLS" \
    "the launch Enter was routed through the agent, which is what answers a dialog"

  # And on the happy path the Enter still goes to the PANE and never the agent.
  new_pane enter-routing-ok
  fm_herdr_launch_line "$PANE" "$LAUNCH_LINE" 200 >/dev/null 2>&1 \
    || fail "launch failed against a ready, echoing pane"
  assert_grep "pane send-keys" "$CALLS" "the launch Enter was not sent to the pane"
  assert_no_grep "agent send-keys" "$CALLS" "the launch Enter was routed through the agent"
  assert_grep "target=pane" "$PTY_ENTERS" "the submitted Enter was not aimed at the pane's shell"
  pass "enter-never-reaches-agent: the launch Enter is the shell's, and a live dialog refuses it"
}

# --- gate-t4-stale-dialog-is-not-live ---------------------------------------
#
# A dialog in scrollback is a dialog that was ANSWERED. Only the agent's own
# lifecycle field separates it from one waiting for an answer now, and that
# field is read as a field: the record carries the crewmate's terminal title
# beside it, which is untrusted rendered text and here spells out every status
# word a grep would look for.
case_stale_dialog_is_not_live() {
  new_pane stale-dialog
  : > "$PTY_AGENT"
  cat > "$PTY_PANE" <<'EOF'
Do you trust the files in this folder?
  Yes, proceed
> No, exit
agent started
> esc to interrupt
EOF
  PTY_AGENT_STATE=idle; export PTY_AGENT_STATE

  if [ "$MUTATE" = 1 ]; then
    fm_herdr_dialog_live "$PANE" && return 0
    fail "MUTATION: a dialog rendered in scrollback was expected to read as live"
  fi
  fm_herdr_dialog_live "$PANE" \
    && fail "a trust dialog left in scrollback was reported as a live dialog"
  PTY_AGENT_STATE=blocked; export PTY_AGENT_STATE
  fm_herdr_dialog_live "$PANE" \
    || fail "a genuinely blocked agent was not reported as holding a live dialog"
  pass "stale-dialog-is-not-live: only the lifecycle field makes a dialog live"
}

# --- gate-t4-ready-shell-adds-no-extra-probes -------------------------------
#
# The cost of the guarantee, pinned. Against a shell that is ready immediately
# the whole gated launch is one readiness probe, one drain sentinel, one text
# send and one Enter - bounded and countable, so "no added latency worth
# noticing" is an assertion rather than an impression.
case_ready_shell_adds_no_extra_probes() {
  new_pane happy-path
  fm_herdr_wait_shell_ready "$PANE" 20 || fail "readiness refused an immediately-ready shell"
  fm_herdr_input_drained "$PANE" 10 || fail "the drain sentinel refused an immediately-ready shell"
  fm_herdr_launch_line "$PANE" "$LAUNCH_LINE" 2000 >/dev/null 2>&1 \
    || fail "launch failed against an immediately-ready shell"

  local runs texts keys
  runs=$(count_calls 'pane run')
  texts=$(count_calls 'pane send-text')
  keys=$(count_calls 'pane send-keys')

  if [ "$MUTATE" = 1 ]; then
    [ "$runs" -gt 2 ] && return 0
    fail "MUTATION: a ready shell was expected to cost more than two probes"
  fi
  [ "$runs" = 2 ] || fail "a ready shell cost $runs probe(s); it must cost exactly 2 (readiness + drain)"
  [ "$texts" = 1 ] || fail "the launch text was sent $texts time(s); it must be sent once"
  [ "$keys" = 1 ] || fail "the launch Enter was sent $keys time(s); it must be sent once"
  [ "$(grep -c 'depth=' "$PTY_ENTERS")" = 3 ] \
    || fail "the pane received $(grep -c 'depth=' "$PTY_ENTERS") submits; a gated launch is exactly 3"
  assert_grep "agent started" "$PTY_PANE" "the agent never started on the happy path"
  [ -s "$PTY_AGENT_IN" ] && fail "the happy-path launch left keystrokes for the agent to inherit"
  pass "ready-shell-adds-no-extra-probes: one extra round trip, and nothing left over"
}

ALL_CASES="enter-waits-for-echo readiness-proves-queue-drained enter-never-reaches-agent stale-dialog-is-not-live ready-shell-adds-no-extra-probes"

run_case() {
  case "$1" in
    enter-waits-for-echo)             case_enter_waits_for_echo ;;
    readiness-proves-queue-drained)   case_readiness_proves_queue_drained ;;
    enter-never-reaches-agent)        case_enter_never_reaches_agent ;;
    stale-dialog-is-not-live)         case_stale_dialog_is_not_live ;;
    ready-shell-adds-no-extra-probes) case_ready_shell_adds_no_extra_probes ;;
    *) fail "unknown case '$1'; known: $ALL_CASES" ;;
  esac
}

if [ $# -gt 0 ]; then
  for c in "$@"; do run_case "$c"; done
else
  # shellcheck disable=SC2086  # the case list is a deliberate word list
  for c in $ALL_CASES; do run_case "$c"; done
fi
