#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# mechanical move - it removes each matched line from data/backlog.md under the
# active firstmate home and appends it, under the same section heading, to the
# secondmate home's data/backlog.md (home resolved from data/secondmates.md). It
# never changes a line's text, never writes into a project (it refuses a home
# that is not a firstmate home), and is idempotent: a key already present in the
# secondmate backlog is reported and skipped, so re-running converges. If any key
# matches neither backlog, nothing is moved. See AGENTS.md project management
# and task lifecycle.
#
# The item's REPORTING CHANNEL moves with it. A brief pins its home into the
# fm-status.sh command - and a scout brief pins its report path the same way -
# so an item routed with those left behind reports into the origin home, where
# the owning supervisor's watcher never looks and its teardown never finds the
# deliverable. So this also carries the item's data/<key>/ dir into the
# destination home and retargets the channel inside its brief at that home - for
# every requested key, including one already there, which makes a re-run the
# full-migration repair path for an item routed before this existed. See the
# block above retarget_brief.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"

[ $# -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2; exit 1; }
ID=$1
shift

secondmate_home() {
  local id=$1 line
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  line=$(grep -E "^- $id( |$)" "$REG" | tail -1 || true)
  [ -n "$line" ] || { echo "error: secondmate $id is not registered in $REG" >&2; return 1; }
  printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^## / { section = $0; next }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# --- routing the reporting channel with the item ----------------------------
#
# A brief carries its reporting command with the home PINNED INTO IT
# (bin/fm-brief.sh): `FM_HOME=<home> FM_STATE_OVERRIDE=<home>/state bash
# <home>/bin/fm-status.sh <id> "<state>: ..."`. Pinning is what stops a
# secondmate's own FM_HOME from diverting an escalation, but it also means the
# command does not follow the item when the item moves. Handing a task to a
# secondmate while leaving that pin behind gives the destination home a task it
# owns and a channel it does not: the crewmate's reports land in the ORIGIN's
# state dir, which the owning supervisor's watcher never polls, and both homes
# end up holding records for one task. Observed live on `fmx-boot-e3`, routed to
# `fmx-plat` and still reporting into the main home.
#
# So the item's `data/<key>/` dir travels with its backlog line, and the
# reporting command inside the brief is retargeted at the destination home. The
# retarget is a NORMALISATION, not a diff: every reporting command in the brief
# is rewritten to name the destination whatever it said before, so re-running a
# handoff repairs an item routed before this existed rather than only fixing
# briefs that happen to move today.
#
# The rewrite is deliberately narrow. It touches the `fm-status.sh` invocation
# and quoted `<key>.status` paths, and nothing else in the brief - a task
# description that names the origin home for its own reasons is the crewmate's
# instructions, not a channel, and rewriting it would corrupt the work.

# All single-quoted paths in <file> ending in /<key>.status, one per line.
brief_status_paths() {
  local file=$1
  awk '
    BEGIN {
      q = sprintf("%c", 39)
      re = q "[^" q "]*\\.status" q
      want = "/" ENVIRON["FM_HANDOFF_KEY"] ".status"
    }
    {
      line = $0
      while (match(line, re)) {
        m = substr(line, RSTART, RLENGTH)
        inner = substr(m, 2, length(m) - 2)
        if (length(inner) >= length(want) &&
            substr(inner, length(inner) - length(want) + 1) == want) {
          print inner
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file"
}

# All FM_HOME='...' pin values in <file>, one per line.
brief_home_pins() {
  local file=$1
  awk '
    BEGIN { q = sprintf("%c", 39); re = "FM_HOME=" q "[^" q "]*" q }
    {
      line = $0
      while (match(line, re)) {
        m = substr(line, RSTART, RLENGTH)
        print substr(m, 10, length(m) - 10)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file"
}

# All absolute paths in <file> ending in /<key>/report.md, one per line.
#
# A scout brief names its deliverable as an absolute path (bin/fm-brief.sh), and
# bin/fm-teardown.sh reads that report from ITS OWN home. So a report path left
# pointing at the origin is the same defect as a status path left there, with a
# worse ending: the crewmate writes the findings into a home that no longer owns
# the task, the owning secondmate never sees them, and its teardown then refuses
# because the deliverable it looks for was never written where it looks.
#
# Only an ABSOLUTE path names a home. A relative data/<key>/report.md resolves
# correctly in whichever home reads it, so it is left alone.
brief_report_paths() {
  local file=$1
  awk '
    BEGIN {
      q = sprintf("%c", 39)
      key = ENVIRON["FM_HANDOFF_KEY"]
      # An empty key would make `want` a substring of every path and this scan
      # never advance. Refusing to scan is the safe direction: the caller
      # validates the result, so a missed rewrite fails loudly rather than hangs.
      if (key == "") exit 0
      want = "/" key "/report.md"
    }
    {
      line = $0
      while ((p = index(line, want)) > 0) {
        e = p + length(want)
        s = p
        while (s > 1) {
          c = substr(line, s - 1, 1)
          if (c == " " || c == "\t" || c == "`" || c == q || c == "\"" || c == "(" || c == "<") break
          s--
        }
        if (substr(line, s, 1) == "/") print substr(line, s, e - s)
        line = substr(line, e)
      }
    }
  ' "$file"
}

# Rewrite <brief> so every fm-status.sh command, every <key>.status path and
# every absolute <key>/report.md path names <home>. Writes to stdout.
retarget_brief_text() {
  local brief=$1
  awk '
    BEGIN {
      q = sprintf("%c", 39)
      cmd_re = "(FM_HOME=" q "[^" q "]*" q " )?(FM_STATE_OVERRIDE=" q "[^" q "]*" q " )?bash " q "[^" q "]*fm-status\\.sh" q
      st_re = q "[^" q "]*\\.status" q
      want = "/" ENVIRON["FM_HANDOFF_KEY"] ".status"
      want_rep = "/" ENVIRON["FM_HANDOFF_KEY"] "/report.md"
      pins = ENVIRON["FM_HANDOFF_PINS"]
      scriptq = ENVIRON["FM_HANDOFF_SCRIPT_Q"]
      statusq = ENVIRON["FM_HANDOFF_STATUS_Q"]
      reportp = ENVIRON["FM_HANDOFF_REPORT"]
      # A degenerate key would make want_rep a substring of every path and the
      # index() scan below never advance. Skipping is the safe direction: the
      # caller validates the result, so a missed rewrite fails loudly, not hangs.
      do_rep = (ENVIRON["FM_HANDOFF_KEY"] != "" && reportp != "")
    }
    {
      line = $0
      out = ""
      while (match(line, cmd_re)) {
        m = substr(line, RSTART, RLENGTH)
        sq = scriptq
        if (sq == "") {
          p = index(m, "bash " q)
          sq = substr(m, p + 5)
        }
        out = out substr(line, 1, RSTART - 1) pins " bash " sq
        line = substr(line, RSTART + RLENGTH)
      }
      line = out line
      out = ""
      while (match(line, st_re)) {
        m = substr(line, RSTART, RLENGTH)
        inner = substr(m, 2, length(m) - 2)
        rep = m
        if (length(inner) >= length(want) &&
            substr(inner, length(inner) - length(want) + 1) == want) {
          rep = statusq
        }
        out = out substr(line, 1, RSTART - 1) rep
        line = substr(line, RSTART + RLENGTH)
      }
      line = out line
      out = ""
      while (do_rep && (p = index(line, want_rep)) > 0) {
        e = p + length(want_rep)
        s = p
        while (s > 1) {
          c = substr(line, s - 1, 1)
          if (c == " " || c == "\t" || c == "`" || c == q || c == "\"" || c == "(" || c == "<") break
          s--
        }
        if (substr(line, s, 1) == "/") {
          out = out substr(line, 1, s - 1) reportp
        } else {
          out = out substr(line, 1, e - 1)
        }
        line = substr(line, e)
      }
      print out line
    }
  ' "$brief"
}

# retarget_brief <brief> <key> <home>: rewrite in place, then PROVE the channel
# moved. A brief whose command shape this cannot rewrite is a hard failure, not
# a silent pass - a half-routed brief is the exact defect being fixed here.
retarget_brief() {
  local brief=$1 key=$2 home=$3 script tmp pin path want_status want_report
  want_status="$home/state/$key.status"
  want_report="$home/data/$key/report.md"
  script="$home/bin/fm-status.sh"
  if [ ! -f "$script" ]; then
    script=""
  fi

  if [ -z "$(FM_HANDOFF_KEY="$key" brief_status_paths "$brief")$(brief_home_pins "$brief")$(FM_HANDOFF_KEY="$key" brief_report_paths "$brief")" ]; then
    echo "note: $brief names no reporting channel; left unchanged" >&2
    return 0
  fi

  tmp="$BRIEF_TMP/retarget.$$"
  FM_HANDOFF_KEY="$key" \
  FM_HANDOFF_PINS="FM_HOME=$(shell_quote "$home") FM_STATE_OVERRIDE=$(shell_quote "$home/state")" \
  FM_HANDOFF_SCRIPT_Q="${script:+$(shell_quote "$script")}" \
  FM_HANDOFF_STATUS_Q="$(shell_quote "$want_status")" \
  FM_HANDOFF_REPORT="$want_report" \
    retarget_brief_text "$brief" > "$tmp" || {
      echo "error: could not retarget the reporting command in $brief" >&2
      return 1
    }
  cat "$tmp" > "$brief"
  rm -f "$tmp"

  while IFS= read -r pin; do
    [ -z "$pin" ] && continue
    if [ "$pin" != "$home" ]; then
      echo "error: $brief still pins FM_HOME=$pin after retargeting to $home" >&2
      return 1
    fi
  done <<EOF
$(FM_HANDOFF_KEY="$key" brief_home_pins "$brief")
EOF

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ "$path" != "$want_status" ]; then
      echo "error: $brief still names the status file $path after retargeting to $home" >&2
      return 1
    fi
  done <<EOF
$(FM_HANDOFF_KEY="$key" brief_status_paths "$brief")
EOF

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ "$path" != "$want_report" ]; then
      echo "error: $brief still names the report file $path after retargeting to $home" >&2
      return 1
    fi
  done <<EOF
$(FM_HANDOFF_KEY="$key" brief_report_paths "$brief")
EOF
}

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    if [ "$section" = "## In flight" ]; then
      IN_FLIGHT+=("$key")
    else
      TO_MOVE+=("$key")
    fi
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

mkdir -p "$SUB_HOME/data"
SUB_EXISTED=0
if [ -f "$SUB_BACKLOG" ]; then
  SUB_EXISTED=1
fi

MAIN_DIR=$(dirname "$MAIN_BACKLOG")
SUB_DIR=$(dirname "$SUB_BACKLOG")
KEYS_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-keys.XXXXXX")
MOVED_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-moved.XXXXXX")
KEPT_FILE=$(mktemp "$MAIN_DIR/.fm-handoff-kept.XXXXXX")
SUB_TMP=$(mktemp "$SUB_DIR/.fm-handoff-sub.XXXXXX")
MAIN_BAK=$(mktemp "$MAIN_DIR/.fm-handoff-main-bak.XXXXXX")
SUB_BAK=$(mktemp "$SUB_DIR/.fm-handoff-sub-bak.XXXXXX")
BRIEF_TMP=$(mktemp -d "$SUB_DIR/.fm-handoff-briefs.XXXXXX")
BRIEF_UNDO="$BRIEF_TMP/undo"
BRIEF_SRC="$BRIEF_TMP/sources"
: > "$BRIEF_UNDO"
: > "$BRIEF_SRC"
CHANGES_STARTED=0
COMMITTED=0

# Undo brief migration in reverse order: remove a dir we created at the
# destination, restore a destination brief we rewrote in place.
brief_undo() {
  local action a b
  [ -f "$BRIEF_UNDO" ] || return 0
  while IFS="$(printf '\t')" read -r action a b; do
    case "$action" in
      created) rm -rf "$a" || true ;;
      rewrote) if [ -f "$b" ]; then cp "$b" "$a" || true; fi ;;
    esac
  done < <(tail -r "$BRIEF_UNDO" 2>/dev/null || tac "$BRIEF_UNDO")
  # Undo must never decide this script's exit status: it runs from the EXIT
  # trap, where a non-zero last command would abandon the temp-file sweep.
  return 0
}

cleanup() {
  if [ "$COMMITTED" -eq 0 ]; then
    brief_undo
    if [ "$CHANGES_STARTED" -eq 1 ]; then
      cp "$MAIN_BAK" "$MAIN_BACKLOG" 2>/dev/null || true
      if [ "$SUB_EXISTED" -eq 1 ]; then
        cp "$SUB_BAK" "$SUB_BACKLOG" 2>/dev/null || true
      else
        rm -f "$SUB_BACKLOG"
      fi
    fi
  fi
  rm -f "$KEYS_FILE" "$MOVED_FILE" "$KEPT_FILE" "$SUB_TMP" "$MAIN_BAK" "$SUB_BAK"
  rm -rf "$BRIEF_TMP"
}
trap cleanup EXIT

# Migrate one key's data/<key>/ dir to the destination home and retarget the
# brief inside it. The copy lands before anything is removed from the origin, so
# a failure anywhere rolls back to a state where the item is still whole here.
migrate_brief() {
  local key=$1 src dst bak
  case "$key" in
    */*|.*|"") echo "note: skipping brief migration for unusable key: $key" >&2; return 0 ;;
  esac
  src="$DATA/$key"
  dst="$SUB_HOME/data/$key"

  if [ -L "$src" ] || [ -L "$dst" ]; then
    echo "error: refusing to migrate through a symlinked brief dir: $src -> $dst" >&2
    return 1
  fi
  if [ -e "$dst" ] && [ ! -d "$dst" ]; then
    echo "error: destination brief path is not a directory: $dst" >&2
    return 1
  fi

  if [ -d "$src" ] && [ ! -d "$dst" ]; then
    cp -R "$src" "$dst" || { echo "error: could not copy $src to $dst" >&2; return 1; }
    printf 'created\t%s\t\n' "$dst" >> "$BRIEF_UNDO"
    printf '%s\n' "$src" >> "$BRIEF_SRC"
    BRIEF_MOVED+=("$key")
  elif [ -d "$src" ] && [ -d "$dst" ]; then
    # Both homes hold one. The destination's is the live copy, so it is neither
    # clobbered nor deleted from under whoever wrote it; the origin's stale one
    # is named rather than removed, because deleting a dir this script did not
    # place there is not a mechanical move.
    BRIEF_STRANDED+=("$src")
  fi

  [ -f "$dst/brief.md" ] || return 0
  bak="$BRIEF_TMP/bak.$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
  cp "$dst/brief.md" "$bak" || { echo "error: could not back up $dst/brief.md" >&2; return 1; }
  printf 'rewrote\t%s\t%s\n' "$dst/brief.md" "$bak" >> "$BRIEF_UNDO"
  retarget_brief "$dst/brief.md" "$key" "$SUB_HOME" || return 1
  BRIEF_ROUTED+=("$key")
  return 0
}

migrate_all_briefs() {
  local key
  for key in "$@"; do
    migrate_brief "$key" || return 1
  done
}

# The origin's copy is removed only once the destination is whole, so this runs
# after COMMITTED - never before, and never on a path that might still roll back.
commit_brief_sources() {
  local src
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    rm -rf "$src" || echo "warn: could not remove the migrated brief dir $src" >&2
  done < "$BRIEF_SRC"
  return 0
}

# Every path that migrates briefs reports what it did, including the repair path
# where no backlog line moves. A dir that silently exists in two homes is the
# duplicate-ownership half of the defect this script exists to fix.
report_brief_outcome() {
  if [ "${#BRIEF_MOVED[@]}" -gt 0 ]; then
    echo "  brief dir moved: ${BRIEF_MOVED[*]}"
  fi
  if [ "${#BRIEF_ROUTED[@]}" -gt 0 ]; then
    echo "  reporting channel retargeted at $SUB_HOME: ${BRIEF_ROUTED[*]}"
  fi
  if [ "${#BRIEF_STRANDED[@]}" -gt 0 ]; then
    echo "  left in place (destination already holds one): ${BRIEF_STRANDED[*]}"
  fi
}

BRIEF_MOVED=()
BRIEF_ROUTED=()
BRIEF_STRANDED=()

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  # Nothing to move, but an item routed before the reporting command travelled
  # with it still points at this home. Re-running the handoff is the repair, and
  # it is a FULL migration: the pre-fix code left the line in the destination
  # backlog and the data/<key>/ dir here, so this path has a dir to carry over
  # and an origin copy to drop, exactly like the moving path.
  if [ "${#ALREADY[@]}" -gt 0 ]; then
    migrate_all_briefs "${ALREADY[@]}" || exit 1
  fi
  COMMITTED=1
  commit_brief_sources
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  report_brief_outcome
  exit 0
fi

if [ "$SUB_EXISTED" -eq 0 ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
fi

printf '%s\n' "${TO_MOVE[@]}" > "$KEYS_FILE"
cp "$MAIN_BACKLOG" "$MAIN_BAK"
if [ "$SUB_EXISTED" -eq 1 ]; then
  cp "$SUB_BACKLOG" "$SUB_BAK"
fi

# Pass 1: drop the matched lines from the main backlog, capturing each removed
# line tagged with the "## " section heading it lived under.
: > "$MOVED_FILE"
awk -v keysfile="$KEYS_FILE" -v movedfile="$MOVED_FILE" '
  BEGIN {
    while ((getline k < keysfile) > 0) { if (k != "") want[k] = 1 }
    section = "## Queued"
  }
  /^## / { section = $0; print; next }
  /^- \[[ x]\] / {
    rest = $0
    sub(/^- \[[ x]\] +/, "", rest)
    id = rest
    sub(/[ \t].*/, "", id)
    if (id in want) { print section "\t" $0 > movedfile; next }
  }
  { print }
' "$MAIN_BACKLOG" > "$KEPT_FILE"

# Pass 2: insert each moved line at the end of its section in the sub backlog,
# creating the section heading if the sub backlog lacks it.
awk -v movedfile="$MOVED_FILE" '
  function flush(sec) {
    if (sec != "" && (sec in items) && !(sec in flushed)) {
      printf "%s", items[sec]
      flushed[sec] = 1
    }
  }
  BEGIN {
    nsec = 0
    while ((getline rec < movedfile) > 0) {
      tab = index(rec, "\t")
      if (tab == 0) continue
      sec = substr(rec, 1, tab - 1)
      line = substr(rec, tab + 1)
      if (!(sec in items)) { order[++nsec] = sec }
      items[sec] = items[sec] line "\n"
    }
    cur = ""
  }
  /^## / { flush(cur); cur = $0; print; next }
  { print }
  END {
    flush(cur)
    for (i = 1; i <= nsec; i++) {
      s = order[i]
      if (!(s in flushed)) {
        print ""
        print s
        printf "%s", items[s]
        flushed[s] = 1
      }
    }
  }
' "$SUB_BACKLOG" > "$SUB_TMP"

CHANGES_STARTED=1
mv "$SUB_TMP" "$SUB_BACKLOG"
mv "$KEPT_FILE" "$MAIN_BACKLOG"

# The reporting channel moves with the line, and every requested key is
# normalised - including one already at the destination, so a re-run repairs an
# item routed before this existed.
migrate_all_briefs "${TO_MOVE[@]}" ${ALREADY[@]+"${ALREADY[@]}"} || exit 1

COMMITTED=1

# Only now, with the destination whole, is the origin's copy removed.
commit_brief_sources

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
report_brief_outcome
