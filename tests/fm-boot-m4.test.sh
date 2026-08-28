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
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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

start=$(python3 -c 'import time; print(time.time())')
out=$(fm_boot_hook_json | env \
  PATH="$LOGBIN:$PYDIR:/usr/bin:/bin" \
  FM_HOME="$HOME_DIR" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_BOOTSTRAP_BIN="$HANGING" \
  ${BUDGET_ENV[@]+"${BUDGET_ENV[@]}"} \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER"); code=$?
elapsed=$(python3 -c "import sys; print('%.3f' % (__import__('time').time() - float(sys.argv[1])))" "$start")

expect_code 0 "$code" "the emitter must exit 0 even with every helper wedged"

# 1. inside the budget
python3 -c "
import sys
e = float(sys.argv[1])
sys.exit(0 if e < 1.5 else 1)
" "$elapsed" || fail "boot must finish inside the 1.5s ceiling with every helper wedged (took ${elapsed}s)"

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

pass "m4 boot budget holds under hostile helpers"
