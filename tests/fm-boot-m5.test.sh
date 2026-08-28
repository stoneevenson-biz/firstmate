#!/usr/bin/env bash
# m5: a section that fails says so. Failure is never silent.
#
# The defect: bin/fm-captain-bootstrap.sh wraps the entire digest in a bare
#   try: ctx += build_digest()
#   except: pass
# so any unexpected exception drops the whole reconciliation digest with no
# trace. A boot that lost all of its fleet context then looks byte-for-byte
# like a healthy one, and the captain acts on a snapshot that silently is not
# there. Degrading is fine; degrading invisibly is the bug.
#
# The contract this gate freezes: when a section builder raises, the emitter
# still emits, and the output carries an explicit UNAVAILABLE marker naming the
# section and the reason. Nothing is ever dropped without a marker.
#
# Faults are injected through FM_BOOT_FORCE_FAIL, a documented test seam that
# makes the named section builder raise - the same shape as the FM_BOOTSTRAP_BIN
# stub seam the digest already uses. A real fault would only exercise failures
# the code already anticipates; the point here is the UNEXPECTED exception, and
# forcing one is the only way to test it.
#
# Mutation (LEDGER_MUTATE=1): the assertions are run against
# bin/fm-captain-bootstrap.sh, which carries the bare `except: pass`. It drops
# the digest silently and emits no marker, so the assertions fail. This keys the
# gate to the marker actually being produced, not to the seam existing.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

assert_present "$FM_BOOT_EMITTER" "bin/fm-boot-context.sh must exist"

TMP=$(fm_test_tmproot fm-boot-m5)
HOME_DIR="$TMP/home"; FLEET="$TMP/fleet"
fm_boot_make_home "$HOME_DIR" 3
fm_boot_make_fleet "$FLEET" 3

UNDER_TEST="$FM_BOOT_EMITTER"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  UNDER_TEST="$ROOT/bin/fm-captain-bootstrap.sh"
fi

run_with_fault() {
  fm_boot_hook_json | env \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_BOOT_FORCE_FAIL="$1" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"
}

# --- a healthy boot carries no marker, so the marker means something ---------
clean=$(fm_boot_run "$HOME_DIR" "$FLEET" FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain) \
  || fail "a healthy boot must exit 0"
clean_ctx=$(fm_boot_context "$clean")
assert_not_contains "$clean_ctx" "UNAVAILABLE" \
  "a healthy boot must carry no UNAVAILABLE marker - otherwise the marker proves nothing"

# --- the digest raising must be visible -------------------------------------
out=$(run_with_fault digest) || fail "a raising digest must not break the hook"
ctx=$(fm_boot_context "$out")
assert_contains "$ctx" "UNAVAILABLE" \
  "a raising digest must leave an explicit UNAVAILABLE marker, not vanish"
assert_contains "$ctx" "digest" \
  "the marker must name the section that failed"
assert_contains "$ctx" "FmBootForcedFault" \
  "the marker must carry the reason, so the failure is diagnosable from the block alone"

# The rest of the block must survive - one failed section is not a total loss.
assert_contains "$ctx" "## Fleet" \
  "a failed digest must not take the fleet section down with it"

# --- the fleet section raising must be visible too --------------------------
out2=$(run_with_fault fleet) || fail "a raising fleet section must not break the hook"
ctx2=$(fm_boot_context "$out2")
assert_contains "$ctx2" "UNAVAILABLE" \
  "a raising fleet section must leave an explicit marker"
assert_contains "$ctx2" "fleet" \
  "the marker must name the fleet section"

# --- total failure still emits, and still says why --------------------------
out3=$(run_with_fault all) || fail "a wholly failed build must still exit 0"
ctx3=$(fm_boot_context "$out3")
assert_contains "$ctx3" "UNAVAILABLE" \
  "even a total failure must emit a marker rather than an empty or absent block"

pass "m5 boot context never fails silently"
