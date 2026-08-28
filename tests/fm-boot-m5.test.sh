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
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-boot-helpers.sh
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

# A generous budget, deliberately. This gate's subject is that failure is never
# silent, not that the budget holds - m4 owns that. Left on the shipped budget,
# a loaded machine can exhaust it before the lock helper runs, the emitter
# correctly degrades to Tier 1, and every assertion here about the digest fails
# for a reason that has nothing to do with silence. That is how this gate froze
# VACUOUS: under the ledger harness the normal arm failed, so the mutation check
# could not bite. A gate must control everything except the one thing it tests.
export FM_BOOT_TOTAL_BUDGET=30
export FM_BOOT_HELPER_TIMEOUT=10

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

# --- a malformed budget must degrade, not detonate --------------------------
#
# The budget values are parsed at import time, outside the guard around the
# build, so a bare float() there takes the whole hook down with a traceback and
# zero stdout - a boot that lost all its context while looking like nothing ran.
# An empty-valued env var is an entirely ordinary thing for a hook config to
# produce, so this is a live failure mode and not a contrived one.
for bad in "" "abc" "-"; do
  bad_out=$(fm_boot_hook_json | env \
    FM_HOME="$HOME_DIR" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_BOOT_TOTAL_BUDGET="$bad" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"); bad_code=$?
  expect_code 0 "$bad_code" "a malformed budget ('$bad') must not take the hook down"
  bad_ctx=$(fm_boot_context "$bad_out")
  [ -n "$bad_ctx" ] || fail "a malformed budget ('$bad') must still inject a block"
  assert_contains "$bad_ctx" "## Fleet" \
    "a malformed budget ('$bad') must still render the fleet, on the default budget"
done

# A non-numeric value is a real misconfiguration and must be visible, not just
# tolerated. An empty value is ordinary absence, so it defaults silently.
noisy=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" \
  FM_BOOT_TOTAL_BUDGET=abc FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$UNDER_TEST")
noisy_ctx=$(fm_boot_context "$noisy")
assert_contains "$noisy_ctx" "UNAVAILABLE" \
  "a non-numeric budget must leave a visible marker, not be silently ignored"
assert_contains "$noisy_ctx" "FM_BOOT_TOTAL_BUDGET" \
  "the marker must name the setting that was wrong"

# --- UNREADABLE IS NOT EMPTY ------------------------------------------------
#
# The failure this section freezes, found by an independent verifier against an
# earlier version of this branch: a boot against a home that did not exist
# printed a fully confident, marker-free block - "0 in flight", "Wake queue:
# empty", "In-flight tasks: none". Byte-identical to a genuinely idle, healthy
# home.
#
# That is the single most consequential lie this block can tell. Recovery keys
# off exactly those lines: they say there is nothing to reconcile. And it was
# reachable through an ordinary FM_HOME misconfiguration, which the
# N-concurrent-firstmates design makes routine.
#
# The earlier m5 missed it because its observable was scoped to section
# builders that RAISE, and none of these paths raise - read_or, wake_queue and
# own_tasks each caught the error and returned the empty value, which is
# indistinguishable from the healthy one.
#
# Two kinds of not-knowing, which must not be conflated:
#   STRUCTURAL - the home or state/ cannot be listed, so the COUNT is unknown
#   DETAIL     - state/ lists fine, one status file will not read; the count is
#                real and must survive, only that detail is marked
unreadable_boot() {
  fm_boot_hook_json | env \
    FM_HOME="$1" \
    FM_BOOT_FLEET_DIR="$FLEET" \
    FM_CTX_WINDOW=probe-session \
    FIRSTMATE_ROLE=captain \
    bash "$UNDER_TEST"
}

# The exact phrases a healthy idle home would print. None may appear when the
# thing they describe could not be read.
assert_no_false_calm() {
  local ctx=$1 label=$2
  assert_contains "$ctx" "UNAVAILABLE" \
    "$label: must carry an explicit marker, not a confident empty block"
  assert_not_contains "$ctx" "0 in flight, 0 need a decision" \
    "$label: must not count to zero off state it could not read"
  assert_not_contains "$ctx" "Wake queue: empty" \
    "$label: must not report an empty queue it could not read"
  assert_not_contains "$ctx" "In-flight tasks: none" \
    "$label: must not report no in-flight tasks it could not read"
}

# 1. a home that does not exist at all
GONE="$TMP/no-such-home"
gone_out=$(unreadable_boot "$GONE") || fail "an absent home must not break the hook"
gone_ctx=$(fm_boot_context "$gone_out")
assert_no_false_calm "$gone_ctx" "absent home"
assert_contains "$gone_ctx" "home is absent" "the marker must say the home is absent"

# 2. state/ present but unreadable
BLIND="$TMP/blind"
fm_boot_make_home "$BLIND" 3
chmod 000 "$BLIND/state"
blind_out=$(unreadable_boot "$BLIND"); blind_code=$?
blind_ctx=$(fm_boot_context "$blind_out")
chmod 755 "$BLIND/state"
expect_code 0 "$blind_code" "an unreadable state/ must not break the hook"
assert_no_false_calm "$blind_ctx" "unreadable state/"

# 3. the wake queue alone is unreadable - the counts are still real
QBLIND="$TMP/qblind"
fm_boot_make_home "$QBLIND" 3
chmod 000 "$QBLIND/state/.wake-queue"
q_out=$(unreadable_boot "$QBLIND"); q_code=$?
q_ctx=$(fm_boot_context "$q_out")
chmod 644 "$QBLIND/state/.wake-queue"
expect_code 0 "$q_code" "an unreadable wake queue must not break the hook"
assert_contains "$q_ctx" "UNAVAILABLE" "an unreadable wake queue must be marked"
assert_not_contains "$q_ctx" "Wake queue: empty" \
  "an unreadable wake queue must never render as empty"
assert_contains "$q_ctx" "In-flight tasks: 3" \
  "a readable state/ must still report its real task count"

# 4. one status file unreadable - marked, but the count survives
DBLIND="$TMP/dblind"
fm_boot_make_home "$DBLIND" 3
chmod 000 "$DBLIND/state/task-2.status"
d_out=$(unreadable_boot "$DBLIND"); d_code=$?
d_ctx=$(fm_boot_context "$d_out")
chmod 644 "$DBLIND/state/task-2.status"
expect_code 0 "$d_code" "an unreadable status file must not break the hook"
assert_contains "$d_ctx" "UNAVAILABLE" "an unreadable status file must be marked"
assert_contains "$d_ctx" "task-2.status" "the marker must name the file it could not read"
assert_contains "$d_ctx" "3 in flight" \
  "a detail we could not read must not discard a count we do have"

# 5. an ABSENT wake queue is genuinely an empty queue, and says so plainly.
# Without this the fix could pass by marking everything, which would make the
# marker meaningless in the other direction.
EMPTYQ="$TMP/emptyq"
fm_boot_make_home "$EMPTYQ" 2
rm -f "$EMPTYQ/state/.wake-queue"
e_out=$(unreadable_boot "$EMPTYQ") || fail "a home with no wake queue must boot"
e_ctx=$(fm_boot_context "$e_out")
assert_contains "$e_ctx" "Wake queue: empty" \
  "an absent wake queue is genuinely empty and must say so, not cry UNAVAILABLE"
assert_not_contains "$e_ctx" "UNAVAILABLE" \
  "ordinary absence must not raise a marker - or the marker means nothing"

pass "m5 boot context never fails silently"
