#!/usr/bin/env bash
# G1: threshold selection. A captain sentinel at total>=185k is selected for
# restart; a crew sentinel at used_pct>=50 is selected; a crew sentinel at the
# absolute token ceiling (total>=200k) is selected EVEN WHEN used_pct<50 (the new
# FM_CTX_CREW_FLOOR ceiling); sub-threshold sentinels are not. Mutation
# (LEDGER_MUTATE=1): drop both the captain total below its floor AND the crew
# absolute-ceiling sentinel below 200k — a correct fm_ctx_select then stops
# selecting them, so the assertions fail (proving the test is keyed to the real
# threshold behavior, including the new crew ceiling, not vacuous).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g1.XXXXXX")
trap 'rm -rf "$STATE"' EXIT

write_ctx() {  # <key> <role> <total> <pct>
  # These sentinels model firstmate-MANAGED panes (managed:true) so the threshold
  # surface is what's under test here; the managed-scope gate is G6.
  printf '{"window":"%s","tmux_target":"%%9","role":"%s","managed":true,"total_tokens":%s,"used_pct":%s,"exceeds_200k":false,"ts":0}' \
    "$1" "$2" "$3" "$4" > "$STATE/ctx-$1.json"
}

CAP_TOTAL=190000
CREW_FLOOR_TOTAL=210000   # crew at the absolute 200k ceiling, but pct<50
[ "${LEDGER_MUTATE:-}" = 1 ] && CAP_TOTAL=170000          # mutation: below the 185k floor
[ "${LEDGER_MUTATE:-}" = 1 ] && CREW_FLOOR_TOTAL=190000   # mutation: below the 200k ceiling

write_ctx caphot    captain "$CAP_TOTAL"        95
write_ctx capcold   captain 170000              80
write_ctx crewhot   crew    50000               60
write_ctx crewfloor crew    "$CREW_FLOOR_TOTAL" 30
write_ctx crewcold  crew    30000               40

sel=$(fm_ctx_select "$STATE")

printf '%s\n' "$sel" | grep -qx caphot    || fail "captain over floor must be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx capcold   && fail "captain under floor must NOT be selected"
printf '%s\n' "$sel" | grep -qx crewhot   || fail "crew over 50% must be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx crewfloor || fail "crew over 200k absolute ceiling (pct<50) must be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx crewcold  && fail "crew under 200k AND under 50% must NOT be selected"

pass "G1 threshold selection (captain>=185k, crew>=50% OR >=200k absolute)"
