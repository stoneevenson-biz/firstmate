#!/usr/bin/env bash
# tests/watch-helpers.sh - fixtures for the supervision-sensing gates (w1..w6).
#
# The watcher is a long-running loop that EXITS on its first wake, so every case
# here is "arrange a fleet, run one watcher, read the one line it printed". The
# two senses need different arrangements and the helpers below build both.
#
# WHY THE PRE-SEEDED COUNTER. Stale needs two consecutive identical observations
# before it reports, so a from-cold watcher would need three poll cycles. Seeding
# .hash-<key>/.count-<key> - exactly as tests/fm-wake-queue.test.sh already does
# for the tmux path - puts the watcher one cycle from its decision and keeps the
# suites fast without weakening what is asserted.

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

FM_WATCH="$ROOT/bin/fm-watch.sh"

# fm_watch_case <root> <name> -> prints a case dir with state/ and a fakebin
# holding BOTH fakes: a herdr that answers `api snapshot`, and a tmux that
# answers capture-pane. Both are always present so a routing mistake shows up as
# the wrong surface being consulted rather than as a missing binary.
fm_watch_case() {  # <tmp-root> <name>
  local dir="$1/$2"
  mkdir -p "$dir/state"
  fm_herdr_fake_server "$dir" >/dev/null
  fm_herdr_fake_tmux "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# fm_watch_meta <state> <id> <window> <mux> <kind>
fm_watch_meta() {  # a meta with no mux= line is written by passing "" for <mux>
  local state=$1 id=$2 window=$3 mux=$4 kind=$5
  {
    printf 'window=%s\n' "$window"
    printf 'worktree=/wt\nproject=/p/demo\nharness=claude\n'
    [ -n "$mux" ] && printf 'mux=%s\n' "$mux"
    printf 'kind=%s\n' "$kind"
  } > "$state/$id.meta"
}

# fm_watch_prime <state> <window> <observation>: put the watcher one cycle from
# its stale decision for this target.
fm_watch_prime() {  # <state> <window> <observation>
  local key; key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s' "$3" > "$1/.hash-$key"
  printf '1\n' > "$1/.count-$key"
}

# fm_watch_run <dir> [limit-tenths] -> runs ONE watcher against the case and
# prints whatever wake line it produced (empty when it never woke). Never leaves
# a watcher behind.
fm_watch_run() {  # <case-dir> [limit]
  local dir=$1 limit=${2:-60} out="$1/watch.out" pid
  : > "$out"
  PATH="$dir/fakebin:$PATH" CALLS="$dir/calls" \
    FM_STATE_OVERRIDE="$dir/state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$FM_WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" "$limit" >/dev/null 2>&1 || true
  cat "$out"
}
