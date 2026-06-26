#!/usr/bin/env bash
# G6: managed-scope. The MEASURE statusLine is GLOBAL, so EVERY Claude session on
# the machine writes a ctx-<window>.json sentinel into firstmate's state/ —
# including Stone's ad-hoc/personal sessions. The daemon must ONLY ever act on
# firstmate-MANAGED panes: a sentinel WITHOUT managed:true that is over threshold
# must NOT be selected; a managed sentinel over threshold IS selected. This is the
# defect-fix surface (the global statusline could otherwise /clear a non-firstmate
# session). Mutation (LEDGER_MUTATE=1): stamp the unmanaged sentinel managed:true —
# a correct fm_ctx_select then DOES select it, so the "must NOT be selected"
# assertion fails (proving the scope check, not a constant, drives the verdict).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g6.XXXXXX")
trap 'rm -rf "$STATE"' EXIT

# write_ctx <key> <managed> <role> <total> <pct>
write_ctx() {
  printf '{"window":"%s","tmux_target":"%%9","managed":%s,"role":"%s","total_tokens":%s,"used_pct":%s,"exceeds_200k":false,"ts":0}' \
    "$1" "$2" "$3" "$4" "$5" > "$STATE/ctx-$1.json"
}

UNMANAGED=false
[ "${LEDGER_MUTATE:-}" = 1 ] && UNMANAGED=true   # mutation: pretend the ad-hoc pane is firstmate's

# Both panes are WAY over threshold; the ONLY difference is the managed flag.
write_ctx managedpane   true        captain 195000 98   # firstmate-owned   -> select
write_ctx adhocpane     "$UNMANAGED" captain 195000 98  # personal/ad-hoc   -> skip

sel=$(fm_ctx_select "$STATE")

printf '%s\n' "$sel" | grep -qx managedpane || fail "managed over-threshold pane MUST be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx adhocpane   && fail "UNMANAGED over-threshold pane must NOT be selected (got: $sel)"

pass "G6 managed-scope (only firstmate-session panes are selected)"
