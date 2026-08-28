#!/usr/bin/env bash
# fm-mux-lib.sh — the multiplexer seam.
#
# firstmate drives panes through ~100 direct `tmux` calls across 15 scripts.
# That couples the fleet to one multiplexer and, worse, to one multiplexer's
# weakest property: `tmux send-keys` is blind keystroke injection with no
# acknowledgment channel. Every supervision primitive built on it is therefore
# a heuristic — busy/idle is a regex over pane text, readiness is a cwd poll,
# and delivery is a fixed sleep between the text and the Enter.
#
# This file is the seam that lets a driver with real acknowledgment replace it.
# The three entry points firstmate uses to create, steer, and observe a direct
# report — fm-spawn.sh, fm-send.sh, fm-peek.sh — are wired onto it.
#
# THE STANDING RULE (captain, data/captain.md "Where agents run", 2026-08-28):
# agents run in herdr, and herdr is the ONLY default. Headless is never selected
# automatically — not by a reachability probe, not by a missing binary, not by
# an environment variable. Any tier may RECOMMEND a headless run, but it asks
# the captain first and he decides. Silent degradation to headless is the
# specific failure the rule exists to prevent: believing he is watching the
# fleet while work happens somewhere he cannot see is worse than knowing it is
# invisible.
#
# So `fm_mux_driver` consults nothing. A rule that asks is a rule that can
# answer "headless". Reachability is still CHECKED — by fm_mux_require_available,
# which ESCALATES when herdr cannot be reached rather than quietly picking
# something else. `FM_MUX` is the explicit, human-chosen override; that is a
# decision already made, not a fallback, so it is honoured silently.
#
# Every verb has one contract across drivers:
#
#   fm_mux_driver                          -> prints the active driver name
#   fm_mux_require_available [what]        -> 0 when it can be reached; escalates otherwise
#   fm_mux_scope <label> <cwd>             -> prints an OPAQUE scope handle
#   fm_mux_window_exists <scope> <name> <label>
#                                          -> 0 when that window/tab is present
#   fm_mux_new_window <scope> <name> <cwd> [label]
#                                          -> prints an OPAQUE target, 1 on failure
#   fm_mux_run <target> <shell-command>    -> runs a short command in a SHELL pane
#   fm_mux_run_launch <target> <command>   -> runs a LONG literal command line
#   fm_mux_send <target> <text>            -> prompts an AGENT; 0 acked, 3 blocked, 4 unconfirmed
#   fm_mux_send_key <target> <key>         -> one key press
#   fm_mux_read <target> [lines]           -> prints pane text
#   fm_mux_cwd <target>                    -> prints the pane's foreground cwd
#   fm_mux_is_busy <target>                -> 0 when the agent is working
#   fm_mux_wait_ready <target> [timeout]   -> 0 when a SHELL can accept a command
#   fm_mux_launch_failed <target>          -> 0 when the pane shows a shell error
#   fm_mux_label <target> <name>           -> names the window/tab for the WORK
#   fm_mux_close <target>                  -> tears the window down
#   fm_mux_resolve <window> <state-dir>    -> sets FM_MUX_TARGET and FM_MUX
#
# `run` and `send` are deliberately separate verbs. Under tmux they are the same
# blind keystrokes, which is exactly why the distinction was invisible before;
# under herdr a shell pane takes `pane run` while a detected agent takes
# `agent prompt --wait`, and only the second one can be acknowledged.
#
# `run` and `run_launch` differ ONLY under tmux, and only because the pre-seam
# code did: `treehouse get` went out as one `send-keys <cmd> Enter` call, while
# the launch line went out as `send-keys -l <cmd>`, a sleep, then `Enter`. Both
# shapes are preserved exactly so FM_MUX=tmux is a true rollback rather than a
# similar-looking code path. herdr has no key-versus-literal ambiguity, so its
# driver maps both onto one `pane run`.
#
# THE TARGET IS OPAQUE. Under tmux it is `session:window`; under herdr it is a
# pane id. Callers must pass it back verbatim and never parse it — that rule is
# what keeps the drivers swappable. `state/<id>.meta` records the target in
# `window=` and the driver that minted it in `mux=`, so a task spawned under one
# driver is always steered by that same driver.
#
# Spec: docs/plans/cmux-herdr-surface-split.md (W1, W2).

# --- driver selection -------------------------------------------------------

# Is a herdr server actually REACHABLE? Not "are we running inside herdr" —
# HERDR_ENV is unset in firstmate's own process even while a server is running
# and the captain is watching it, so this is the only correct way to ask.
#
# It is a DIAGNOSTIC, never a selector. Nothing here picks a driver from its
# answer; fm_mux_require_available uses it to escalate. This is the canonical
# owner of the check; bin/fm-herdr-workspaces.sh defers to it rather than
# keeping a second copy.
fm_mux_herdr_up() {
  command -v herdr >/dev/null 2>&1 || return 1
  herdr session list 2>/dev/null | awk '$1=="default"{print $2}' | grep -q running
}

# Driver selection, in full. An explicit FM_MUX is the captain's word (or an
# operator's, on his authority) and wins. Absent that, herdr — always, with
# nothing consulted and nothing to probe. There is deliberately no branch here
# that can produce a headless driver on its own.
fm_mux_driver() {
  if [ -n "${FM_MUX:-}" ]; then printf '%s' "$FM_MUX"; return 0; fi
  printf 'herdr'
}

# Precondition for putting an AGENT somewhere: can the chosen driver actually be
# reached? Call this before creating a pane, never to choose one.
#
# When herdr cannot be reached this returns non-zero with an escalation, and the
# caller must STOP. It must not fall back, because falling back is the decision
# the captain reserved for himself. The message says what is wrong, whose call
# it is, and the exact thing he would say to authorise a headless run — a tier
# may recommend headless, but it recommends by printing this and stopping.
#
# An explicitly chosen NON-herdr driver is a decision already made and is never
# second-guessed. An explicit FM_MUX=herdr is still checked: choosing herdr does
# not make an unreachable server reachable, and the agent has to go somewhere.
fm_mux_require_available() {  # [what-for]
  local what=${1:-this agent} drv
  drv=$(fm_mux_driver)
  [ "$drv" = herdr ] || return 0
  if fm_mux_herdr_up; then return 0; fi
  {
    echo "fm-mux: cannot place $what - no herdr server is reachable."
    if command -v herdr >/dev/null 2>&1; then
      echo "  herdr is installed but no server is running. Start or attach one with \`herdr\`."
    else
      echo "  herdr is not on PATH. Install it, or run this where a server is reachable."
    fi
    echo "  NOT falling back to a headless pane: where agents run is the captain's"
    echo "  decision, and a pane he cannot see does not count. If this particular"
    echo "  run genuinely belongs headless, ask the captain and re-run with FM_MUX=tmux."
  } >&2
  return 1
}

fm_mux_dispatch() {  # <verb> [args...]
  local verb=$1; shift
  local drv; drv=$(fm_mux_driver)
  case "$drv" in
    tmux|herdr) ;;
    *) echo "fm-mux: unknown FM_MUX driver '$drv' (want tmux|herdr)" >&2; return 2 ;;
  esac
  "fm_mux_${drv}_${verb}" "$@"
}

fm_mux_scope()          { fm_mux_dispatch scope          "$@"; }
fm_mux_window_exists()  { fm_mux_dispatch window_exists  "$@"; }
fm_mux_new_window()     { fm_mux_dispatch new_window     "$@"; }
fm_mux_run()            { fm_mux_dispatch run            "$@"; }
fm_mux_run_launch()     { fm_mux_dispatch run_launch     "$@"; }
fm_mux_send()           { fm_mux_dispatch send           "$@"; }
fm_mux_send_key()       { fm_mux_dispatch send_key       "$@"; }
fm_mux_read()           { fm_mux_dispatch read           "$@"; }
fm_mux_cwd()            { fm_mux_dispatch cwd            "$@"; }
fm_mux_is_busy()        { fm_mux_dispatch is_busy        "$@"; }
fm_mux_wait_ready()     { fm_mux_dispatch wait_ready     "$@"; }
fm_mux_launch_failed()  { fm_mux_dispatch launch_failed  "$@"; }
fm_mux_label()          { fm_mux_dispatch label          "$@"; }
fm_mux_close()          { fm_mux_dispatch close          "$@"; }

# --- naming -----------------------------------------------------------------
#
# Pane naming is the ADDRESS, not decoration (bin/fm-herdr-workspaces.sh owns
# the convention). A task id like `afs-resources-r7` tells you nothing at a
# glance; `afs-resource-registry` tells you both the project and the work
# without attaching to the pane.
#
# THE CONVENTION: <project-short>-<what-the-work-is>, kebab-case, under 28 chars.
#   afs-resource-registry   mac-config-cutover-guard   cellarsky-booking-fix
#   firstmate-fleet-view    firstmate-hook-register    archify-leak-fixes
# One HYPHEN joins the halves. Never a slash — verified against herdr 0.8.2,
# `herdr agent rename` rejects anything but ^[a-z][a-z0-9_-]{0,31}$ with
# invalid_agent_name, so a `<project>/<work>` form is not merely unconventional,
# it is UNADDRESSABLE: every rename it produces fails and the pane keeps a name
# nobody chose. The separator is gated against the real binary, so putting a
# slash back turns that gate red rather than quietly shipping.
#
# 28 chars keeps the name readable in herdr's sidebar (sidebar_width 30) and
# inside the 32-char address limit at once. No task suffix — the id lives in
# state/<id>.meta, which is where an id belongs.

fm_mux_name_max=28

# Sanitize one half of a name. Anything herdr would reject is removed here
# rather than discovered at rename time.
fm_mux_work_name() {  # <work...>
  printf '%s' "$*" | tr '[:upper:]' '[:lower:]' | tr ' _/' '-' \
    | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^[^a-z]*//; s/-*$//'
}

# The full pane name: project, one hyphen, work. Over-length truncates the WORK
# half — callers that would rather refuse than accept a name the captain did not
# choose check the length themselves before calling.
fm_mux_pane_name() {  # <project-short> <work...>
  local proj=$1; shift
  local work room name
  proj=$(fm_mux_work_name "$proj")
  work=$(fm_mux_work_name "$@")
  [ -n "$proj" ] || { fm_mux_work_name "$@" | cut -c "1-$fm_mux_name_max"; return 0; }
  [ -n "$work" ] || { printf '%s' "$proj" | cut -c "1-$fm_mux_name_max"; return 0; }
  room=$(( fm_mux_name_max - ${#proj} - 1 ))
  if [ "$room" -lt 1 ]; then
    printf '%s' "$proj" | cut -c "1-$fm_mux_name_max" | sed 's/-*$//'
    return 0
  fi
  work=$(printf '%s' "$work" | cut -c "1-$room" | sed 's/-*$//')
  name="$proj-$work"
  printf '%s' "$name"
}

# 0 when a name is one herdr will actually accept as an agent address. This is
# the check a slash fails, and the reason the separator is a hyphen.
fm_mux_name_valid() {  # <name>
  case "$1" in
    '' ) return 1 ;;
    *[!a-z0-9_-]* ) return 1 ;;
    [!a-z]* ) return 1 ;;
  esac
  [ "${#1}" -le "$fm_mux_name_max" ]
}

# --- tmux driver ------------------------------------------------------------
#
# Preserves today's behaviour exactly, including its known weaknesses, so
# switching FM_MUX back is a true rollback rather than a different code path.

# Same session when firstmate already runs inside tmux; dedicated session otherwise.
fm_mux_tmux_scope() {  # <label> <cwd>  (both ignored: tmux scopes by session, not project)
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf '%s\n' firstmate
  fi
}

# tmux identifies a window by its protocol NAME; herdr by the label the captain
# reads. Both verbs take both, and each driver reads the one it addresses by.
fm_mux_tmux_window_exists() {  # <session> <name> <label>
  tmux list-windows -t "$1" -F '#{window_name}' 2>/dev/null | grep -qx "$2"
}

fm_mux_tmux_new_window() {  # <session> <name> <cwd> [label]  (label is herdr-only)
  local ses=$1 name=$2 cwd=$3
  tmux new-window -d -t "$ses:" -n "$name" -c "$cwd" 2>/dev/null || return 1
  printf '%s:%s' "$ses" "$name"
}

# A short command line, sent as one call with the Enter key - byte-identical to
# the pre-seam `tmux send-keys -t "$T" 'treehouse get' Enter`.
fm_mux_tmux_run() {  # <target> <shell-command>
  tmux send-keys -t "$1" "$2" Enter 2>/dev/null
}

# The launch line: typed literally, then submitted after a beat - byte-identical
# to the pre-seam `send-keys -l "$LAUNCH"; sleep 0.3; send-keys Enter`. Blind
# keystrokes with no acknowledgment to wait on; that is the tmux weakness.
fm_mux_tmux_run_launch() {  # <target> <command>
  fm_mux_tmux_send "$@"
}

fm_mux_tmux_send() {  # <target> <text>
  local target=$1 text=$2
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || return 1
  sleep "${FM_MUX_ENTER_SLEEP:-0.3}"
  tmux send-keys -t "$target" Enter 2>/dev/null || return 1
}

fm_mux_tmux_send_key() {  # <target> <key>
  tmux send-keys -t "$1" "$2"
}

fm_mux_tmux_read() {  # <target> [lines]
  local target=$1 lines=${2:-40}
  tmux capture-pane -p -t "$target" -S "-$lines" 2>/dev/null
}

fm_mux_tmux_cwd() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# Busy is inferred from the harness's own footer text. This is the heuristic
# the herdr driver replaces with a real state read.
fm_mux_tmux_is_busy() {  # <target>
  fm_mux_tmux_read "$1" 6 | grep -qiE "${FM_BUSY_RE:-esc (to )?interrupt|Working\.\.\.}"
}

fm_mux_tmux_wait_ready() {  # <target> [timeout]
  if command -v fm_tmux_wait_shell_ready >/dev/null 2>&1; then
    fm_tmux_wait_shell_ready "$1" "${2:-20}"
  else
    sleep "${FM_MUX_ENTER_SLEEP:-0.3}"
  fi
}

fm_mux_tmux_launch_failed() {  # <target>
  if command -v fm_tmux_launch_failed >/dev/null 2>&1; then
    fm_tmux_launch_failed "$1"
  else
    fm_mux_launch_error_text "$(fm_mux_tmux_read "$1" 15)"
  fi
}

# tmux window names are protocol, not display: fm-watch scans for `fm-*` and the
# meta's window= is `<session>:<name>`. Renaming would break both, so the tmux
# driver deliberately does not carry the work name; it reports that plainly
# rather than claiming a naming it did not do.
fm_mux_tmux_label() {  # <target> <name>
  return 0
}

fm_mux_tmux_close() {  # <target>
  tmux kill-window -t "$1" 2>/dev/null
}

# --- herdr driver -----------------------------------------------------------
#
# herdr classifies agent lifecycle natively (idle|working|blocked|done) and
# `agent prompt --wait` delivers text and submission as one acknowledged
# operation. That removes the two guesses the tmux driver is forced into.
#
# Responses are single-line JSON over the socket API. jq is NOT a firstmate
# dependency, so fields are pulled with targeted sed; records are split on `{`
# first so a per-record grep cannot straddle two objects.

fm_mux_herdr_field() {  # <json> <key>   -> first matching "key":"value"
  printf '%s' "$1" | tr '{' '\n' | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

# --- workspace scoping ---
#
# TRAP: `herdr tab create` without --workspace lands the tab in whatever
# workspace happens to be FOCUSED. That is luck, not targeting, and it is how a
# crewmate ends up in the captain's config workspace. The workspace is therefore
# always resolved explicitly, and never hardcoded — ids like `wJ` are runtime
# values that do not survive a server restart.
#
# Resolution order, per the captain's one-workspace-per-project order:
#   1. FM_HERDR_WORKSPACE — an explicit override; a label if one matches, else
#      taken as a literal workspace id.
#   2. the workspace whose LABEL is the project name.
#   3. neither exists -> CREATE it, labelled for the project. Creating is the
#      documented policy: refusing would strand the first spawn into any new
#      project, and falling back to focus is the bug this replaces.
# A creation failure is fatal to the spawn — never a silent focus fallback.

fm_mux_herdr_ws_id_for_label() {  # <label>
  herdr workspace list 2>/dev/null | tr '{' '\n' \
    | grep -F "\"label\":\"$1\"" \
    | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p' | head -1
}

fm_mux_herdr_ws_exists() {  # <workspace-id>
  herdr workspace list 2>/dev/null | tr '{' '\n' \
    | grep -qF "\"workspace_id\":\"$1\""
}

fm_mux_herdr_scope() {  # <label> <cwd>
  local label=$1 cwd=${2:-} ws out
  if [ -n "${FM_HERDR_WORKSPACE:-}" ]; then
    ws=$(fm_mux_herdr_ws_id_for_label "$FM_HERDR_WORKSPACE")
    [ -n "$ws" ] || ws=$FM_HERDR_WORKSPACE
    if fm_mux_herdr_ws_exists "$ws"; then printf '%s' "$ws"; return 0; fi
    echo "fm-mux(herdr): FM_HERDR_WORKSPACE='$FM_HERDR_WORKSPACE' matches no live workspace" >&2
    return 1
  fi
  ws=$(fm_mux_herdr_ws_id_for_label "$label")
  if [ -n "$ws" ]; then printf '%s' "$ws"; return 0; fi
  out=$(herdr workspace create --cwd "$cwd" --label "$label" --no-focus 2>&1) || {
    echo "fm-mux(herdr): could not create workspace '$label': $out" >&2; return 1; }
  ws=$(fm_mux_herdr_field "$out" workspace_id)
  [ -n "$ws" ] || ws=$(fm_mux_herdr_ws_id_for_label "$label")
  [ -n "$ws" ] || { echo "fm-mux(herdr): created workspace '$label' but no id came back" >&2; return 1; }
  printf '%s' "$ws"
}

fm_mux_herdr_window_exists() {  # <workspace-id> <name> <label>
  local label=${3:-$2}
  herdr tab list --workspace "$1" 2>/dev/null | tr '{' '\n' \
    | grep -qF "\"label\":\"$label\""
}

fm_mux_herdr_new_window() {  # <workspace-id> <name> <cwd> [label]
  local ws=$1 name=$2 cwd=$3 label=${4:-} out pane
  [ -n "$label" ] || label=$name
  out=$(herdr tab create --workspace "$ws" --cwd "$cwd" --label "$label" --no-focus 2>&1) || {
    echo "fm-mux(herdr): tab create failed: $out" >&2; return 1; }
  pane=$(fm_mux_herdr_field "$out" pane_id)
  [ -n "$pane" ] || { echo "fm-mux(herdr): tab create returned no pane id: $out" >&2; return 1; }
  printf '%s' "$pane"
}

# A shell pane, not an agent: `pane run` types the command line and submits it.
# One shape covers both callers - herdr takes a command string, so there is no
# key-versus-literal distinction to preserve.
fm_mux_herdr_run() {  # <target> <shell-command>
  local out
  out=$(herdr pane run "$1" "$2" 2>&1) && return 0
  echo "fm-mux(herdr): pane run failed: $out" >&2
  return 1
}

fm_mux_herdr_run_launch() {  # <target> <command>
  fm_mux_herdr_run "$@"
}

# Atomic delivery. --wait makes herdr confirm the agent actually consumed the
# prompt, which is the acknowledgment tmux cannot provide. A blocked agent is
# refused rather than written over (herdr >= 0.8.2 returns agent_blocked).
#
# Return codes are the whole contract here, because "did it land" is the only
# question a supervisor actually has:
#   0  delivered AND acknowledged - the agent consumed it
#   3  refused: the agent is blocked at an approval dialog, nothing was sent
#   4  delivered but NOT acknowledged - see below
#   1  failed
#
# WHY 4 IS NOT 1. herdr accepts the submission first and only then waits for a
# state change; when none arrives it returns agent_prompt_stalled (or timeout)
# AFTER the text has already gone in. Observed live against a claude TUI that
# herdr reported as idle while it was still finishing its boot. Calling that a
# failure would be the worse error of the two available: firstmate would re-send
# a steer that already landed and the crewmate would be told twice. So a stall
# is reported as delivered-but-unconfirmed, matching the tmux path's standing
# rule that only a POSITIVELY CONFIRMED swallow counts as not-sent.
fm_mux_herdr_send() {  # <target> <text>
  local target=$1 text=$2 out
  out=$(herdr agent prompt "$target" "$text" --wait --timeout "${FM_MUX_SEND_TIMEOUT_MS:-15000}" 2>&1) || true
  case "$out" in
    *agent_blocked*)
      echo "fm-mux(herdr): $target is at an approval dialog; not overwriting it" >&2; return 3 ;;
    *agent_prompt_stalled*|*'"code":"timeout"'*)
      echo "fm-mux(herdr): $target took the prompt but never changed state; delivery is unconfirmed, NOT re-sent" >&2
      return 4 ;;
    *agent_not_found*)
      # herdr has not detected an agent in this pane. Fall back to blind shell
      # delivery so the steer still lands, but say so: this delivery is the
      # tmux-grade unacknowledged one, and a caller reading the log must know.
      echo "fm-mux(herdr): no detected agent in $target; delivering unacknowledged via the shell" >&2
      fm_mux_herdr_run "$target" "$text" ;;
    *'"error"'*)
      echo "fm-mux(herdr): prompt failed: $out" >&2; return 1 ;;
    '' )
      echo "fm-mux(herdr): prompt produced no response for $target" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

fm_mux_herdr_send_key() {  # <target> <key>
  herdr agent send-keys "$1" "$2" >/dev/null 2>&1 || herdr pane send-keys "$1" "$2" >/dev/null 2>&1
}

fm_mux_herdr_read() {  # <target> [lines]
  herdr agent read "$1" --source visible --lines "${2:-40}" --format text 2>/dev/null \
    || herdr pane read "$1" --source visible --lines "${2:-40}" --format text 2>/dev/null
}

fm_mux_herdr_cwd() {  # <target>
  fm_mux_herdr_field "$(herdr pane get "$1" 2>/dev/null)" foreground_cwd
}

# A real state read, not a regex over rendered text.
fm_mux_herdr_is_busy() {  # <target>
  herdr agent get "$1" 2>/dev/null | grep -qiE '(^|[^a-z])(working|busy)([^a-z]|$)'
}

# Shell readiness, not agent readiness: at this point the pane holds a bare
# shell and `agent wait` would fail. Same positive proof the tmux path demands —
# a marker echoed back on a line of its own, so the command echo cannot pass for
# the output (see fm_tmux_wait_shell_ready and the 2026-08-26 incident).
fm_mux_herdr_wait_ready() {  # <target> [timeout-seconds]
  local target=$1 timeout=${2:-${FM_SHELL_READY_TIMEOUT:-20}}
  local poll=${FM_SHELL_READY_POLL:-0.2} marker deadline waited
  marker="fmready$$$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -cd '0-9')"
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    fm_mux_herdr_run "$target" "printf '%s\\n' $marker" >/dev/null 2>&1 || return 1
    waited=0
    while [ "$waited" -lt 10 ]; do
      sleep "$poll"
      waited=$((waited + 1))
      if fm_mux_herdr_read "$target" 40 | grep -qx "$marker"; then return 0; fi
    done
  done
  return 1
}

fm_mux_herdr_launch_failed() {  # <target>
  fm_mux_launch_error_text "$(fm_mux_herdr_read "$1" 15)"
}

# Name the tab for the work. The SAME name goes in both slots — the tab label
# the captain reads and, once herdr has detected an agent, the socket-API
# address it is steered by.
#
# The tab label is the gated half and its failure is reported: an unnamed tab is
# the exact defect this work exists to remove, so it must never be assumed. The
# agent rename is best effort by timing alone — herdr classifies the agent a
# beat after launch — and a spawn must not die waiting for it.
# Returns: 0 both named, 1 tab named but no agent yet, 2 the tab rename failed.
fm_mux_herdr_label() {  # <target> <name>
  local target=$1 name=$2 tab out
  if ! fm_mux_name_valid "$name"; then
    echo "fm-mux(herdr): '$name' is not a valid pane name (want ^[a-z][a-z0-9_-]{0,$((fm_mux_name_max-1))}$)" >&2
    return 2
  fi
  tab=$(fm_mux_herdr_field "$(herdr pane get "$target" 2>/dev/null)" tab_id)
  if [ -z "$tab" ]; then
    echo "fm-mux(herdr): no tab found for $target; cannot name it" >&2
    return 2
  fi
  if ! out=$(herdr tab rename "$tab" "$name" 2>&1); then
    echo "fm-mux(herdr): tab rename failed for $tab: $out" >&2
    return 2
  fi
  herdr agent rename "$target" "$name" >/dev/null 2>&1 || return 1
  return 0
}

fm_mux_herdr_close() {  # <target>
  local tab
  tab=$(fm_mux_herdr_field "$(herdr pane get "$1" 2>/dev/null)" tab_id)
  if [ -n "$tab" ]; then herdr tab close "$tab" >/dev/null 2>&1 && return 0; fi
  herdr tab close "$1" >/dev/null 2>&1 || herdr pane close "$1" >/dev/null 2>&1
}

# --- target resolution ------------------------------------------------------
#
# Map what a caller typed onto (driver, opaque target). Sets two globals rather
# than printing, because the DRIVER has to survive into the caller's shell and a
# command substitution would strip it: a crewmate spawned as a herdr tab must be
# steered with herdr verbs even from a process where herdr no longer resolves,
# and a tmux crewmate must never be probed with herdr ones.
#
#   FM_MUX_TARGET  the opaque target to pass back to the seam verbs
#   FM_MUX         the driver that minted it, when the meta records one
#
# Accepts: a bare firstmate window name (fm-xyz) resolved through this home's
# state/<id>.meta; an explicit opaque target (session:window, or a herdr pane
# id - both carry a colon); or a plain tmux window name, looked up across
# sessions, which is a tmux-only convenience and stays one.
# shellcheck disable=SC2034  # FM_MUX_TARGET is the point: it is read by the caller, not here
fm_mux_resolve() {  # <window-or-target> <state-dir>
  local want=$1 state=$2 meta window drv
  case "$want" in
    *:*)
      # Checked FIRST, exactly as the pre-seam resolve() had it: an argument
      # carrying a colon is an explicit target and wins over any name-shaped
      # reading of it, so a session literally named `fm-something` still
      # addresses `fm-something:window` rather than being looked up as a task id.
      #
      # A raw target with no meta behind it. The documented form here is
      # `session:window` - a tmux address - so tmux is what it means unless the
      # caller says otherwise with FM_MUX. Ambient resolution would be wrong and
      # dangerous: on any machine with a herdr server up, `fm-peek sess:win`
      # would be answered by herdr verbs aimed at a tmux address, and quietly
      # return nothing. The target stays OPAQUE - the driver comes from the
      # caller's declaration, never from parsing the string's shape.
      [ -n "${FM_MUX:-}" ] || FM_MUX=tmux
      FM_MUX_TARGET=$want
      ;;
    fm-*)
      meta="$state/${want#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $want in $state; pass session:window to target a window outside this firstmate home" >&2
        return 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
      drv=$(grep '^mux=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      # A meta with no mux= predates the seam, so it is a tmux target by
      # definition. Pinning it is what stops a herdr-default process from
      # aiming herdr verbs at `firstmate:fm-old`.
      [ -n "$drv" ] || drv=tmux
      FM_MUX=$drv
      FM_MUX_TARGET=$window
      ;;
    *)
      window=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -m1 ":$want\$") \
        || { echo "error: no window named $want" >&2; return 1; }
      FM_MUX=tmux
      FM_MUX_TARGET=$window
      ;;
  esac
  return 0
}

# --- shared helpers ---------------------------------------------------------

# Post-launch verification. If the launch string reached the shell as text
# instead of starting the agent, the shell says so — and firstmate should fail
# loudly rather than record a meta for a pane that holds nothing.
fm_mux_launch_error_text() {  # <pane-text>
  printf '%s' "$1" | grep -qiE 'parse error|command not found|syntax error near|no such file or directory'
}
