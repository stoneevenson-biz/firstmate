#!/usr/bin/env bash
# tests/herdr-helpers.sh - fakes for the multiplexer seam.
#
# THE RULE THESE FAKES EXIST TO ENFORCE: a gate must not pass against a stub
# that would never satisfy the real multiplexer. So the fake herdr here is not
# a yes-machine. It reproduces the constraints verified against herdr 0.8.2:
#
#   * `agent rename` REJECTS anything but ^[a-z][a-z0-9_-]{0,31}$ with
#     invalid_agent_name - which is what proved the old `<project>/<work>`
#     naming convention unusable;
#   * `tab create` without --workspace is a bug, not a default, so the fake
#     records the flag and the tests assert on it;
#   * `agent prompt` on a blocked agent returns agent_blocked BEFORE sending;
#   * responses are single-line JSON over the socket API.
#
# Live coverage against a real server lives in the *-live gates; these fakes
# carry the branches a live run cannot reach on demand (no server, blocked
# agent, rejected name).

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_herdr_fake_server <dir> -> prints a fakebin dir holding a herdr stub.
# Behaviour knobs, all read at call time from the environment:
#   HERDR_SERVER      running|stopped   (default running)
#   HERDR_WORKSPACES  "id=label,id=label"  the workspaces that already exist
#   HERDR_BLOCKED     1 -> agent prompt returns agent_blocked
#   HERDR_NO_AGENT    1 -> agent prompt/get return agent_not_found
#   HERDR_PANE_CWD    what `pane get` reports as foreground_cwd
#   HERDR_PANE_FILE   file whose contents `agent read`/`pane read` return
#   CALLS             file every invocation's argv is appended to
fm_herdr_fake_server() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
ws_json() {
  local out='{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":['
  local first=1 pair id label
  IFS=,; for pair in ${HERDR_WORKSPACES:-}; do
    [ -n "$pair" ] || continue
    id=${pair%%=*}; label=${pair#*=}
    [ "$first" = 1 ] || out="$out,"
    first=0
    out="$out{\"label\":\"$label\",\"workspace_id\":\"$id\"}"
  done
  unset IFS
  printf '%s]}}\n' "$out"
}
case "$1 $2" in
  "session list")
    printf 'name                 status   directory\ndefault              %s  /x\n' "${HERDR_SERVER:-running}" ;;
  "workspace list") ws_json ;;
  "workspace create")
    # A created workspace joins the live set for the rest of this process tree.
    label=""; while [ $# -gt 0 ]; do [ "$1" = --label ] && label=$2; shift; done
    printf '{"id":"cli:workspace:create","result":{"workspace":{"label":"%s","workspace_id":"wNEW"},"type":"workspace_created"}}\n' "$label"
    printf '%s\n' "wNEW=$label" >> "${HERDR_WS_CREATED:-/dev/null}" ;;
  "tab list")
    printf '{"id":"cli:tab:list","result":{"tabs":[' 
    if [ -s "${HERDR_TABS:-/dev/null}" ]; then
      first=1
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"label":"%s","tab_id":"wT:t9"}' "$l"
      done < "${HERDR_TABS:-/dev/null}"
    fi
    printf '],"type":"tab_list"}}\n' ;;
  "tab create")
    ws=""; label=""; cwd=""
    while [ $# -gt 0 ]; do
      case "$1" in --workspace) ws=$2 ;; --label) label=$2 ;; --cwd) cwd=$2 ;; esac
      shift
    done
    if [ -z "$ws" ]; then
      # The real trap: an unscoped create lands wherever focus happens to be.
      echo '{"error":{"code":"missing_workspace","message":"refusing an unscoped tab create"}}' >&2
      exit 1
    fi
    printf '%s\n' "$label" >> "${HERDR_TABS:-/dev/null}"
    printf '{"id":"cli:tab:create","result":{"root_pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s:p2","tab_id":"%s:t2"},"tab":{"label":"%s","tab_id":"%s:t2"},"type":"tab_created"}}\n' \
      "$cwd" "$cwd" "$ws" "$ws" "$label" "$ws" ;;
  "tab rename")
    # Free text: a tab label has no character restriction.
    printf '%s\n' "$3" >> "${HERDR_TABS:-/dev/null}"
    printf '{"id":"cli:tab:rename","result":{"type":"ok"}}\n' ;;
  "tab close")   printf '{"id":"cli:tab:close","result":{"type":"ok"}}\n' ;;
  "pane get")
    # HERDR_NO_TAB drops tab_id, the shape a caller sees when herdr cannot give
    # a tab to rename - which is how a pane ends up unnamed.
    if [ "${HERDR_NO_TAB:-0}" = 1 ]; then
      printf '{"id":"cli:pane:get","result":{"pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s"},"type":"pane_info"}}\n' \
        "${HERDR_PANE_CWD:-/proj}" "${HERDR_PANE_CWD:-/proj}" "$3"
    else
      printf '{"id":"cli:pane:get","result":{"pane":{"cwd":"%s","foreground_cwd":"%s","pane_id":"%s","tab_id":"wT:t9"},"type":"pane_info"}}\n' \
        "${HERDR_PANE_CWD:-/proj}" "${HERDR_PANE_CWD:-/proj}" "$3"
    fi ;;
  "pane run")
    # A shell that actually runs what it is given: the readiness probe depends
    # on the marker coming back on a line of its own, exactly as under tmux.
    case "$3" in
      "printf '%s\n' "*) printf '%s\n' "${3##*\' }" >> "${HERDR_PANE_FILE:-/dev/null}" ;;
    esac
    printf '{"id":"cli:pane:run","result":{"type":"ok"}}\n' ;;
  "pane read"|"agent read") cat "${HERDR_PANE_FILE:-/dev/null}" 2>/dev/null ;;
  "pane close")  printf '{"id":"cli:pane:close","result":{"type":"ok"}}\n' ;;
  "agent get")
    [ "${HERDR_NO_AGENT:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}'; exit 1; }
    printf '{"id":"cli:agent:get","result":{"agent":{"agent_status":"%s"},"type":"agent_info"}}\n' "${AGENT_STATE:-idle}" ;;
  "agent prompt")
    [ "${HERDR_BLOCKED:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_blocked","message":"agent is blocked"}}'; exit 1; }
    # herdr accepts the submission and THEN waits for a state change; when none
    # arrives the text has already gone in. Observed live against a claude TUI
    # herdr reported as idle while it was still booting.
    [ "${HERDR_STALLED:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed state change within 5000 ms"}}'; exit 1; }
    [ "${HERDR_NO_AGENT:-0}" = 1 ] && {
      echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}'; exit 1; }
    case "$*" in
      *--wait*) : ;;
      # Unacknowledged delivery is the tmux weakness this driver exists to fix.
      *) echo '{"error":{"code":"unacknowledged","message":"prompt without --wait"}}' >&2; exit 1 ;;
    esac
    printf '{"id":"cli:agent:prompt","result":{"agent":{"agent_status":"done"},"type":"agent_info"}}\n' ;;
  "agent rename")
    name=$4
    # THE REAL CONSTRAINT, verified against herdr 0.8.2.
    if printf '%s' "$name" | grep -qE '^[a-z][a-z0-9_-]{0,31}$'; then
      printf '{"id":"cli:agent:rename","result":{"type":"ok"}}\n'
    else
      printf '{"error":{"code":"invalid_agent_name","message":"agent name must start with a lowercase letter and contain only lowercase letters, digits, %s-%s or %s_%s (1-32 characters)"},"id":"cli:agent:rename"}\n' "'" "'" "'" "'"
      exit 1
    fi ;;
  "agent send-keys") printf '{"id":"cli:agent:send-keys","result":{"type":"ok"}}\n' ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fm_herdr_fake_tmux <dir> -> a tmux that records argv and answers the few reads
# the seam performs. TMUX_RC forces a failure; PANE_FILE backs capture-pane.
fm_herdr_fake_tmux() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  capture-pane) cat "${PANE_FILE:-/dev/null}" 2>/dev/null ;;
  display-message)
    # Two different reads share this verb: the session name (#S) and the pane's
    # cwd (#{pane_current_path}). Answering both with one value would make the
    # treehouse-get wait resolve instantly to a bogus worktree.
    case "$*" in
      *pane_current_path*) printf '%s\n' "${TMUX_CWD:-}" ;;
      *) printf '%s\n' "${TMUX_SESSION:-firstmate}" ;;
    esac ;;
  list-windows) printf '%s\n' "${TMUX_WINDOWS:-}" ;;
  has-session) exit "${TMUX_HAS_SESSION:-0}" ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        "printf '%s\n' "*) printf '%s\n' "${a##*\' }" >> "${PANE_FILE:-/dev/null}" ;;
      esac
    done ;;
esac
exit "${TMUX_RC:-0}"
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A herdr binary that is absent entirely: PATH with no herdr on it at all.
fm_herdr_path_without_binary() {
  local p out=""
  IFS=:; for p in $PATH; do
    [ -n "$p" ] || continue
    [ -x "$p/herdr" ] && continue
    out="${out:+$out:}$p"
  done
  unset IFS
  printf '%s\n' "$out"
}

# assert_eq <actual> <expected> <msg> - the shape most of these gates need, and
# one that avoids the `A && pass || fail` idiom shellcheck flags as ambiguous.
assert_eq() {
  if [ "$1" = "$2" ]; then return 0; fi
  fail "$3 (expected '$2', got '$1')"
}
