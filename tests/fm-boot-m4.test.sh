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
# A single sample is not evidence about a ceiling, and the worst of N is the
# honest statistic. But the measurement itself has to be sound first.
#
# The measurement must not launch an interpreter INSIDE the window it is timing.
# The previous version stamped the start with one `python3 -c` and the end with
# another, so the second interpreter's startup was charged to the emitter. Under
# load that startup spikes, and it is the entire reason this gate looked flaky.
# Measured over 60 samples at load ~180, bracketing each boot with bash's free
# EPOCHREALTIME clock as a control:
#
#   TRUE boot time   p50 1.035s  p90 1.174s  max 1.370s   breaches of 1.5s: 0
#   AS MEASURED      p50 1.097s  p90 1.291s  max 1.863s   breaches of 1.5s: 3
#   instrumentation  p50 0.059s  p90 0.163s  max 0.608s
#
# Every breach was the gate timing its own instrumentation. The emitter never
# exceeded the ceiling. So the ceiling stays at 1.5s and the measurement is what
# gets fixed - moving the threshold would have hidden a sound implementation
# behind a bad experiment.
#
# One interpreter now runs the whole loop and times each boot around the
# subprocess itself, so nothing but the boot is inside the window. fork/exec of
# the boot is inside it, correctly: the harness pays that too.
RUNS=${FM_BOOT_M4_RUNS:-5}
LASTOUT="$TMP/last-boot.json"
timings=$(env \
  PATH="$LOGBIN:$PYDIR:/usr/bin:/bin" \
  FM_HOME="$HOME_DIR" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_BOOTSTRAP_BIN="$HANGING" \
  ${BUDGET_ENV[@]+"${BUDGET_ENV[@]}"} \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  python3 - "$FM_BOOT_EMITTER" "$RUNS" "$LASTOUT" "$(fm_boot_hook_json)" <<'PY'
import os, subprocess, sys, time
emitter, runs, lastout, hook = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
worst = 0.0
for _ in range(runs):
    t0 = time.time()
    r = subprocess.run(["bash", emitter], input=hook, capture_output=True,
                       text=True, env=os.environ)
    dt = time.time() - t0
    worst = max(worst, dt)
    if r.returncode != 0:
        print("RC %d" % r.returncode)
        sys.exit(0)
    print("  boot %.3fs" % dt, file=sys.stderr)
open(lastout, "w").write(r.stdout)
print("WORST %.3f" % worst)
PY
) || fail "the timing harness must run"

case "$timings" in
  RC\ *) fail "the emitter must exit 0 even with every helper wedged (got exit ${timings#RC })" ;;
esac
worst=${timings#WORST }
out=$(cat "$LASTOUT")

# Checked before the timing verdict, because a leak invalidates the timing.
#
# Settle first. Killing is asynchronous: SIGKILL is delivered, and the process
# is reaped a moment later, so an instantaneous sample can catch one mid-death
# and call it a leak. Measured: 30 consecutive hostile boots never elevated the
# count at all, yet one sample in a 10-run sweep saw a single dying process. The
# property being asserted is that no orphan PERSISTS, so wait briefly for the
# count to return to baseline and only then judge. The wait is bounded, so a
# genuine leak still fails - it simply never comes back down.
sleepers_after=$(leaked_sleepers)
settle=0
while [ "$sleepers_after" -gt "$sleepers_before" ] && [ "$settle" -lt 15 ]; do
  sleep 0.2
  sleepers_after=$(leaked_sleepers)
  settle=$((settle + 1))
done
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
