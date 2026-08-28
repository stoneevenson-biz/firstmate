#!/usr/bin/env bash
# fm-herdr-workspaces.sh — one herdr workspace per fleet project, and a naming
# rule for agent panes.
#
# THE ORGANISING RULE (captain's standing order, 2026-08-27):
#   * every project gets its OWN workspace, labelled with the project name
#   * every agent pane is NAMED FOR THE WORK IT IS DOING, not for a task id
#
# A task id like `afs-resources-r7` tells you nothing at a glance.
# `afs-resource-registry` tells you both the project and the work without
# attaching to the pane. herdr addresses agents by unique name (`herdr agent
# prompt <name> ...`), so the name is not decoration - it is the address, and a
# good one makes the fleet legible from the workspace list alone.
#
# Naming convention:  <project-short>-<what-the-work-is>, kebab, under 28 chars
#   afs-resource-registry   mac-config-cutover-guard   cellarsky-booking-fix
#   firstmate-fleet-view    firstmate-hook-register    archify-leak-fixes
# One HYPHEN joins the halves. No task suffix - the id lives in
# state/<id>.meta, which is where an id belongs.
#
# THE SEPARATOR IS A HYPHEN, NEVER A SLASH, and that is not a style preference.
# Verified against herdr 0.8.2: `herdr agent rename` rejects anything but
# ^[a-z][a-z0-9_-]{0,31}$ with invalid_agent_name. The `<project>/<work>` form
# this file once carried could therefore never be applied at all - every rename
# it produced failed and the pane kept a name nobody chose. A live gate pins the
# separator against the real binary, so restoring a slash turns that gate red.
# 28 chars keeps the name readable in the sidebar (sidebar_width 30) and inside
# herdr's 32-char address limit at once.
# bin/fm-mux-lib.sh owns the sanitizer and the validity check.
#
# Usage:
#   fm-herdr-workspaces.sh              show the plan, change nothing
#   fm-herdr-workspaces.sh --apply      create the missing workspaces
#   fm-herdr-workspaces.sh --name <target> <project-short> <work...>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REGISTRY="$FM_HOME/data/projects.md"
PROJECTS_DIR="$FM_HOME/projects"

# The multiplexer seam owns the reachability predicate and the naming rules;
# one fact, one owner. This file stays the place the CONVENTION is documented.
# shellcheck source=bin/fm-mux-lib.sh
. "$SCRIPT_DIR/fm-mux-lib.sh"

die() { printf 'fm-herdr-workspaces: %s\n' "$1" >&2; exit 1; }

herdr_up() { fm_mux_herdr_up; }

require_herdr() {
  command -v herdr >/dev/null 2>&1 || die "herdr is not on PATH"
  herdr_up || die "no herdr server is running — run \`herdr\` to start or attach it, then retry"
}

# --name: apply the convention to a live agent pane. Names BOTH slots - the tab
# label the captain reads and the agent address herdr steers by - with the same
# string, because they are the same name.
if [ "${1:-}" = "--name" ]; then
  require_herdr
  [ $# -ge 4 ] || die "usage: --name <target> <project-short> <what-the-work-is>"
  target=$2; proj=$3; shift 3
  name=$(fm_mux_pane_name "$proj" "$*")
  [ -n "$name" ] || die "'$proj' + '$*' leaves nothing usable as a name"
  # Refuse an unreadably long name rather than silently truncating it: a name
  # the captain did not choose is worse than being told to choose a shorter one.
  # (fm_mux_pane_name truncates for callers that must not fail, such as a spawn.)
  untruncated="$(fm_mux_work_name "$proj")-$(fm_mux_work_name "$*")"
  [ "${#untruncated}" -le 28 ] \
    || die "'$untruncated' is ${#untruncated} chars; keep it under 28, e.g. afs-resource-registry"
  # The separator is a hyphen because herdr will not accept anything else. This
  # check is what makes putting a slash back a RED gate rather than a silent
  # no-op rename.
  fm_mux_name_valid "$name" \
    || die "'$name' is not a name herdr will accept as an address (want ^[a-z][a-z0-9_-]{0,31}$ - a slash is rejected)"
  fm_mux_herdr_label "$target" "$name" || die "herdr did not accept '$name' for $target"
  printf 'named %s -> %s\n' "$target" "$name"
  exit 0
fi

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$REGISTRY" ] || die "no project registry at $REGISTRY"
require_herdr

existing=$(herdr workspace list 2>/dev/null || true)

printf '%-26s %-9s %s\n' PROJECT STATUS CWD
printf '%-26s %-9s %s\n' "-------" "------" "---"
made=0; skipped=0; missing=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  cwd="$PROJECTS_DIR/$name"
  if [ ! -d "$cwd" ]; then
    printf '%-26s %-9s %s\n' "$name" "NO-DIR" "$cwd"; missing=$((missing+1)); continue
  fi
  if printf '%s' "$existing" | grep -qw -- "$name"; then
    printf '%-26s %-9s %s\n' "$name" "exists" "$cwd"; skipped=$((skipped+1)); continue
  fi
  if [ "$APPLY" = 1 ]; then
    herdr workspace create --cwd "$cwd" --label "$name" --no-focus >/dev/null \
      && { printf '%-26s %-9s %s\n' "$name" "CREATED" "$cwd"; made=$((made+1)); } \
      || printf '%-26s %-9s %s\n' "$name" "FAILED" "$cwd"
  else
    printf '%-26s %-9s %s\n' "$name" "would-add" "$cwd"; made=$((made+1))
  fi
done < <(sed -n 's/^- \([a-z0-9][a-z0-9._-]*\) .*/\1/p' "$REGISTRY")

printf '\n'
if [ "$APPLY" = 1 ]; then
  printf 'created %s, already present %s, no directory %s\n' "$made" "$skipped" "$missing"
else
  printf 'plan only: %s to create, %s present, %s missing a directory\n' "$made" "$skipped" "$missing"
  printf 'run with --apply to create them.\n'
fi
