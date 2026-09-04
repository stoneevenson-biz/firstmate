#!/usr/bin/env bash
# fm-state-lib.sh - the one owner of "which files in state/ belong to task <id>".
#
# THE DEFECT THIS EXISTS FOR. bin/fm-teardown.sh removed a finished task's
# window, worktree and the seven state files it knew by name, and left every
# marker the WATCHER had minted for that task behind: `.seen-<id>_status`,
# `.seen-<id>_turn-ended`, and the per-pane `.hash-`/`.count-`/`.stale-` trio.
# Nothing ever removed them, because the code that creates them (bin/fm-watch.sh)
# and the code that ends the task (bin/fm-teardown.sh) each knew half the naming
# rule and neither knew the other's half. Measured on the captain's home on
# 2026-09-02: 195 entries in state/, of which 9 belonged to live work.
#
# That is not only untidy. Every one of those names is a SUPPRESSOR. `.seen-*`
# says "this signal was already reported" and `.stale-*` says "this exact
# stalled state was already reported", so a task id or a pooled pane id that
# comes back around inherits a marker that silences its first real wake. The
# residue is a supervision hazard with a long fuse.
#
# So the naming rule gets ONE implementation, here, and both sides ask it:
# fm-watch.sh mints markers through fm_state_key/fm_state_seen_marker, and
# fm-teardown.sh removes them through fm_state_prune_task. Neither restates the
# rule, so they cannot drift apart again.
#
# fm_state_task_residue is deliberately NOT built from the same list. It SCANS
# the state dir for anything still named after the task, so a file added to the
# fleet tomorrow and forgotten in the prune list is caught by the gate rather
# than silently accumulating - a list checked against itself would only ever
# prove it agrees with itself.

# fm_state_key <target>: the marker key for a pane/window target. A herdr pane
# id and a tmux session:window both carry characters that cannot appear in a
# filename fragment, so ':', '/', '.' and whitespace collapse to '_'. This is
# the same rule fm_ctx_sanitize_key applies in bin/fm-ctx-lib.sh; the gate
# asserts the two agree.
fm_state_key() {
  printf '%s' "$1" | tr ':/. ' '____'
}

# fm_state_seen_marker <state> <signal-file>: the `.seen-*` path fm-watch.sh
# compares a status or turn-end file against. The signal file's basename has its
# dots collapsed, so state/<id>.status -> state/.seen-<id>_status.
fm_state_seen_marker() {
  local state=$1 file=$2
  printf '%s/.seen-%s\n' "$state" "$(basename "$file" | tr '.' '_')"
}

# fm_state_task_paths <state> <id> [window]: every state path this task owns -
# the id-named files, the watcher's signal markers, and the per-pane markers
# keyed off its window. Emitted whether or not each exists, one per line, so a
# caller can prune or report without re-deriving any name.
fm_state_task_paths() {
  local state=$1 id=$2 window=${3:-} key
  [ -n "$state" ] || return 0
  [ -n "$id" ] || return 0

  # Named for the task id.
  printf '%s\n' \
    "$state/$id.status" \
    "$state/$id.turn-ended" \
    "$state/$id.check.sh" \
    "$state/$id.meta" \
    "$state/$id.pi-ext.ts" \
    "$state/$id.verifying" \
    "$state/$id.orphan-pane" \
    "$state/$id.intake" \
    "$state/$id.verdict"

  # The watcher's signal suppressors, derived from the signal files above so the
  # two names can never disagree.
  fm_state_seen_marker "$state" "$state/$id.status"
  fm_state_seen_marker "$state" "$state/$id.turn-ended"

  # Named for the task's pane. The stale-sense trio, plus the context
  # watchdog's per-pane sentinels - the pane is being closed, so nothing will
  # ever read them again.
  [ -n "$window" ] || return 0
  key=$(fm_state_key "$window")
  [ -n "$key" ] || return 0
  printf '%s\n' \
    "$state/.hash-$key" \
    "$state/.count-$key" \
    "$state/.stale-$key" \
    "$state/.ctx-fired-$key" \
    "$state/ctx-$key.json" \
    "$state/handoff-$key.md" \
    "$state/resume-$key.directive"
}

# fm_state_prune_task <state> <id> [window] [keep-basename...]: remove every
# path fm_state_task_paths names, except any whose basename is listed in keep.
# The keep list exists for exactly one caller: a teardown that could NOT close
# the pane keeps <id>.orphan-pane, which is the only durable record naming the
# leftover pane.
fm_state_prune_task() {
  local state=$1 id=$2 window=${3:-} path base keep skip
  if [ "$#" -gt 3 ]; then shift 3; else set --; fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    base=$(basename "$path")
    skip=0
    for keep in "$@"; do
      [ "$base" = "$keep" ] && { skip=1; break; }
    done
    [ "$skip" = 1 ] && continue
    rm -f "$path"
  done <<EOF
$(fm_state_task_paths "$state" "$id" "$window")
EOF
}

# fm_state_task_residue <state> <id> [window]: every entry still in <state> that
# is NAMED after this task - scanned, not listed, so it catches names the prune
# list has never heard of. Reporting only: no caller removes what this returns,
# because a task id that is a prefix of a live one would match here.
fm_state_task_residue() {
  local state=$1 id=$2 window=${3:-} key f base
  [ -d "$state" ] || return 0
  [ -n "$id" ] || return 0
  key=""
  [ -n "$window" ] && key=$(fm_state_key "$window")
  for f in "$state"/* "$state"/.*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      .|..) continue ;;
    esac
    case "$base" in
      "$id".*|.seen-"$id"_*) printf '%s\n' "$f"; continue ;;
    esac
    [ -n "$key" ] || continue
    case "$base" in
      *-"$key"|*-"$key".*) printf '%s\n' "$f" ;;
    esac
  done
}
