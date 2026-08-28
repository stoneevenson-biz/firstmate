#!/usr/bin/env bash
# m4: the boot budget holds under hostile conditions.
#
# The failure this gate exists to prevent is not slowness - it is silence. A
# SessionStart hook that exceeds its declared timeout injects NOTHING, and a
# session that boots blind looks exactly like one that booted well. The old
# path allowed two serial 5s helper timeouts against a declared 10s hook
# timeout, so one wedged helper cost the whole block.
#
# Hostile conditions, all at once:
#   - every helper the emitter may exec is stubbed to `sleep 999`
#   - 12 synthetic peers in the fleet view, one corrupt, one long stale
#
# Under that, the emitter must:
#   1. finish inside the total wall-clock budget (1.5s)
#   2. print valid JSON carrying a SessionStart envelope
#   3. keep additionalContext under the 10,000-char injection cap
#   4. render a degradation marker for each helper it could not reach, rather
#      than a plausible-looking line or nothing at all
#   5. list all 12 peers - a peer is NEVER elided (per-task detail may be)
#   6. perform ZERO execs on the peer path
#
# On the timeout arithmetic: the design's section 7 set a 1.5s total ceiling AND
# a 2s per-helper timeout for two helpers, which is 4s and cannot satisfy this
# gate. The tracked spec's Erratum section reconciles it - the 1.5s total is
# authoritative, per-helper drops to 0.6s, and a shared deadline bounds the
# whole helper phase so adding a third helper can never breach the total. This
# gate is the executable form of that reconciliation.
#
# (6) is proved structurally, not by timing: the emitter runs under a PATH whose
# only entries are stub dirs, and every stub records its own invocation. Any exec
# attributable to a peer would show up in the log.
#
# Mutation (LEDGER_MUTATE=1): the emitter is handed the pre-split budget - a
# generous 5s per helper under a 30s ceiling. An emitter that honours its
# configured budget then waits both wedged helpers out and takes ~10s, so the
# hard-coded "< 1.5s" assertion fails. This keys the gate to the deadline being
# genuinely enforced, rather than to the stubs happening to return quickly.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-boot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

assert_present "$FM_BOOT_EMITTER" "bin/fm-boot-context.sh must exist"

TMP=$(fm_test_tmproot fm-boot-m4)
HOME_DIR="$TMP/home"; FLEET="$TMP/fleet"
fm_boot_make_home "$HOME_DIR" 4
fm_boot_make_fleet "$FLEET" 12

HANGING=$(fm_boot_hanging_bin "$TMP")

# The normal arm passes no budget overrides at all, so it exercises the values
# the emitter actually ships with. The mutation arm relaxes both, which is the
# pre-split configuration: generous per-helper timeouts and no total ceiling.
BUDGET_ENV=()
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  BUDGET_ENV=(FM_BOOT_TOTAL_BUDGET=30 FM_BOOT_HELPER_TIMEOUT=5)
fi

# Every exec the emitter attempts is logged, so claim (6) is checkable.
EXECLOG="$TMP/exec.log"
: > "$EXECLOG"
LOGBIN="$TMP/logbin"; mkdir -p "$LOGBIN"
for tool in ps tmux git; do
  cat > "$LOGBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$EXECLOG"
exit 1
SH
  chmod +x "$LOGBIN/$tool"
done

# PATH keeps the real python3 reachable (the emitter needs it) but puts the
# logging stubs ahead of everything, so any exec the emitter attempts for ps,
# tmux or git is recorded rather than performed.
PYDIR=$(dirname "$(command -v python3)")

hostile_boot() {
  fm_boot_hook_json | env \
    PATH="$LOGBIN:$PYDIR:/usr/bin:/bin" \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_BOOTSTRAP_BIN="$HANGING" \
    ${BUDGET_ENV[@]+"${BUDGET_ENV[@]}"} \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$FM_BOOT_EMITTER"
}

# 0. the boot must not leak processes.
#
# This assertion exists because its absence invalidated every measurement this
# gate had ever taken. subprocess kills the helper it started but not what that
# helper spawned, so each wedged boot orphaned two `sleep 999` processes to
# init. Five per test run, accumulating across runs: 194 of them were live at
# once, carrying the load average to 186 - and the boots this gate was timing
# then took ~2s against a 1.5s ceiling. The gate was failing because of its own
# side effects, and it read as flakiness. A single run passed; six in a row did
# not. Any timing assertion below is worthless without this one above it.
# ps, not pgrep: this must match the FULL argv exactly. `pgrep -x` matches the
# process name only, so it cannot distinguish `sleep 999` from any other sleep,
# and `pgrep -f` substring-matches, which would also match this very pipeline.
# shellcheck disable=SC2009
leaked_sleepers() { ps -eo args | grep -c '^sleep 999$'; }
sleepers_before=$(leaked_sleepers)

# 1. inside the budget - measured over REPEATED runs, judged on the WORST.
#
# A single sample is not evidence about a ceiling. The first version of this
# gate took one, and hid a real defect: the budget clock started inside python,
# so it never counted interpreter startup, and the ceiling was breached in about
# 28% of runs while the gate passed most of the time. A gate that is 72% green
# is worse than a red one, because it launders a defect as flake. The worst of
# N runs is the honest statistic, and it makes the gate deterministic.
RUNS=${FM_BOOT_M4_RUNS:-5}
worst=0
out=""
code=0
for _ in $(seq 1 "$RUNS"); do
  start=$(python3 -c 'import time; print(time.time())')
  out=$(hostile_boot); code=$?
  elapsed=$(python3 -c "import sys; print('%.3f' % (__import__('time').time() - float(sys.argv[1])))" "$start")
  expect_code 0 "$code" "the emitter must exit 0 even with every helper wedged"
  worst=$(python3 -c "import sys; print('%.3f' % max(float(sys.argv[1]), float(sys.argv[2])))" "$worst" "$elapsed")
done

# Checked before the timing verdict, because a leak invalidates the timing.
sleepers_after=$(leaked_sleepers)
leaked=$((sleepers_after - sleepers_before))
[ "$leaked" -le 0 ] || fail "a wedged helper must be killed as a process group, not left \
running: $RUNS boots orphaned $leaked processes. That is a production leak, and it also \
poisons this gate - the orphans load the machine and the next run's timing measures them."

python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.5 else 1)" "$worst" \
  || fail "every boot must finish inside the 1.5s ceiling with every helper wedged (worst of $RUNS runs: ${worst}s)"

# 2. valid envelope
ctx=$(fm_boot_context "$out")

# 3. under the injection cap
n=${#ctx}
[ "$n" -lt 10000 ] \
  || fail "injected context must stay under the 10,000-char cap (got $n chars)"

# 4. degradation markers instead of invented lines
assert_contains "$ctx" "UNAVAILABLE" \
  "a wedged helper must render an explicit UNAVAILABLE marker"
assert_not_contains "$ctx" "watcher-status: healthy" \
  "a wedged watcher helper must not be reported as healthy"

# 5. every peer present - a peer is never elided
missing=""
for i in $(seq 1 12); do
  case "$ctx" in
    *"peer-$i"*) : ;;
    *) missing="$missing peer-$i" ;;
  esac
done
[ -z "$missing" ] || fail "every peer must be listed, never elided (missing:$missing)"
assert_contains "$ctx" "unreadable" \
  "the corrupt peer must render exactly one explicit marker"
assert_contains "$ctx" "stale" \
  "the long-stale peer must render a staleness marker"

# 6. zero execs on the peer path. Peer ids must never appear in the exec log.
if [ -s "$EXECLOG" ]; then
  for i in $(seq 1 12); do
    if grep -q "peer-$i" "$EXECLOG"; then
      fail "the peer path must perform zero execs, but something exec'd for peer-$i:"$'\n'"$(cat "$EXECLOG")"
    fi
  done
fi

# 7. one hostile peer must not be able to spend the whole output budget.
#
# Tier 1 is deliberately uncapped so that assertion 5 can hold, which means a
# single unbounded field in a peer file is enough to breach the injection cap
# without eliding anything. A 20,000-char id did exactly that. Fields are
# bounded; peers are not.
BIGFLEET="$TMP/bigfleet"
fm_boot_make_fleet "$BIGFLEET" 3
python3 - "$BIGFLEET/peer-3.json" <<'PY'
import json, sys
json.dump({"id": "x" * 20000, "in_flight": 1, "needs_decision": 0,
           "watcher": "y" * 20000}, open(sys.argv[1], "w"))
PY
big=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$BIGFLEET" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER") || fail "a hostile peer field must not break the boot"
big_ctx=$(fm_boot_context "$big")
[ "${#big_ctx}" -lt 10000 ] \
  || fail "one peer with an unbounded field must not breach the 10,000-char cap (got ${#big_ctx})"
assert_contains "$big_ctx" "peer-1" "the other peers must still be listed"
assert_contains "$big_ctx" "peer-2" "the other peers must still be listed"

# 8. where the two rules genuinely collide, the choice is stated.
#
# At a fleet size far outside the design envelope, "a peer is never elided" and
# "stay under the injection cap" cannot both hold. The peer rule wins - a
# session that cannot see a peer has lost the thing this block exists for -
# but the block must say so rather than quietly overrun.
HUGE="$TMP/huge"
fm_boot_make_fleet "$HUGE" 200
huge=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$HUGE" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER") || fail "an oversized fleet must not break the boot"
huge_ctx=$(fm_boot_context "$huge")
listed=$(printf '%s\n' "$huge_ctx" | grep -c '^- peer-')
[ "$listed" -eq 200 ] \
  || fail "all 200 peers must be listed even past the cap (listed: $listed)"
assert_contains "$huge_ctx" "injection cap - UNAVAILABLE" \
  "overrunning the cap to keep every peer must be stated, never silent"

pass "m4 boot budget holds under hostile helpers"
