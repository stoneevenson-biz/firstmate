#!/usr/bin/env bash
# T1 (severity): the intake council's severity bar. The council had never once
# proceeded in 96 verdicts because every imperfection mapped to revise, so this
# gate pins the exit condition that was missing:
#   1. two NON-BLOCKING findings -> proceed, with the notes riding along;
#   2. one genuine blocker       -> still revise (unanimity on blockers kept);
#   3. any escalate              -> still escalate;
#   4. a missing or malformed PANEL line -> still escalate (fail closed).
# Case 1 is the point. Case 2 is what stops this from being "approve everything".
# The models are stubbed out through FM_INTAKE_CMD so the gate tests SYNTHESIS,
# not a model's mood; the stub dispatches on the lens name in its prompt.
# Mutation (LEDGER_MUTATE=1): the notes stub emits a bare `revise` instead of
# `proceed-with-notes` - a correct implementation then blocks, and case 1's
# proceed assertions fail.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-t1s)
S="$TMP/state"; D="$TMP/data"; PROJ="$TMP/proj"
mkdir -p "$S" "$D" "$PROJ"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
export FM_LENS_CMD="echo stub-lens-review"

brief() { mkdir -p "$D/$1"; printf '# Task\nBuild %s.\n# Definition of done\ntest green.\n' "$1" > "$D/$1/brief.md"; }

# A dispatching thinker stub: FM_INTAKE_CMD is one command for both lenses, so
# the stub reads the lens name out of the prompt it is handed as $1.
# $ARCH / $RISK are the PANEL payloads it emits for each.
mkstub() {  # <path> <architecture-panel> <risk-panel>
  cat > "$1" <<SH
#!/usr/bin/env bash
case "\$1" in
  *"the architecture lens"*) echo "Considered the seam."; echo "$2" ;;
  *"the risk lens"*)         echo "Considered the hazards."; echo "$3" ;;
  *)                          echo "unknown lens" ;;
esac
SH
  chmod +x "$1"
}

NOTES_VERDICT='PANEL: proceed-with-notes - the helper could be named better and one more test would be nice'
[ "${LEDGER_MUTATE:-}" = 1 ] && NOTES_VERDICT='PANEL: revise - the helper could be named better'

# --- 0. the grammar must be able to SAY "non-blocking" -----------------------
# This is the root defect: with only proceed|revise|escalate, a reviewer holding
# a real but non-blocking finding has nowhere to put it. It either vetoes the
# spawn or is thrown away. proceed-with-notes is the missing word.
#
# The verdict word must also be the WHOLE word. A thinker that could not choose
# ("proceed/revise"), got the grammar wrong ("proceed_with_notes") or is guessing
# ("proceed?") must not be read as a clean proceed just because a separator
# terminated the prefix - that is the one direction this parse may not be loose
# in. Transport noise (a trailing space or CR) carries no meaning and is not a
# malformed verdict, so it is still read.
for pair in \
  'PANEL: proceed |proceed' \
  'PANEL: proceed - ok|proceed' \
  'PANEL: proceed-with-notes - x|proceed-with-notes' \
  'PANEL: revise - x|revise' \
  'PANEL: escalate - x|escalate' \
  'PANEL: proceed|proceed' \
  'PANEL: proceed-with-notes|proceed-with-notes' \
  'PANEL: proceeds - x|invalid' \
  'PANEL: PROCEED - x|invalid' \
  'no panel line at all|invalid' \
  '|invalid' \
  'PANEL: |invalid' \
  'PANEL: proceed/revise - unsure|invalid' \
  'PANEL: proceed?|invalid' \
  'PANEL: proceed_with_notes|invalid' \
  'PANEL: proceed- - x|invalid'; do
  got=$(fm_intake_verdict "${pair%%|*}" 2>/dev/null || echo MISSING)
  [ "$got" = "${pair##*|}" ] || fail "fm_intake_verdict '${pair%%|*}': expected ${pair##*|}, got $got"
done
got=$(fm_intake_verdict "$(printf 'PANEL: proceed - ok\r')" 2>/dev/null || echo MISSING)
[ "$got" = proceed ] || fail "a trailing CR is transport noise, not a malformed verdict (got $got)"

# --- 1. two non-blocking findings -> PROCEED, notes carried along -------------
brief t1notes
mkstub "$TMP/both-notes.sh" \
  "$NOTES_VERDICT" \
  'PANEL: proceed-with-notes - the scope could be trimmed by one file'
out=$(FM_INTAKE_CMD="$TMP/both-notes.sh" "$ROOT/bin/fm-intake.sh" t1notes "$PROJ" 2>&1); code=$?
expect_code 0 "$code" "two non-blocking findings must exit 0 (proceed)"
F=$(fm_intake_file "$S" t1notes)
[ "$(fm_intake_last "$S" t1notes)" = proceed ] || fail "last decision must be proceed for non-blocking findings"
assert_no_grep "revise:" "$F" "a non-blocking finding must not spend a revise"
assert_grep "named better" "$F" "the non-blocking note must ride along on the proceed line"
assert_grep "trimmed by one file" "$D/t1notes/intake-review.md" "notes must land in the synthesis for the brief to absorb"
assert_contains "$out" "proceed: task t1notes" "proceed reported on stdout"

# A bare `proceed` mixed with `proceed-with-notes` is still non-blocking.
brief t1mixed
mkstub "$TMP/mixed.sh" \
  'PANEL: proceed - seam and DoD check out' \
  'PANEL: proceed-with-notes - consider a clearer error string'
FM_INTAKE_CMD="$TMP/mixed.sh" "$ROOT/bin/fm-intake.sh" t1mixed "$PROJ" >/dev/null 2>&1; code=$?
expect_code 0 "$code" "proceed + proceed-with-notes must exit 0"
assert_grep "clearer error string" "$(fm_intake_file "$S" t1mixed)" "the note rides along"

# --- 2. one genuine blocker -> STILL REVISE ----------------------------------
# Unanimity on blockers is a feature: one reviewer seeing real harm stops the spawn.
brief t1block
mkstub "$TMP/one-blocker.sh" \
  'PANEL: proceed-with-notes - the helper could be named better' \
  'PANEL: revise - the sweep safe-set would close panes holding live work'
FM_INTAKE_CMD="$TMP/one-blocker.sh" "$ROOT/bin/fm-intake.sh" t1block "$PROJ" >/dev/null 2>&1; code=$?
expect_code 2 "$code" "a single genuine blocker must still exit 2 (revise)"
F=$(fm_intake_file "$S" t1block)
assert_grep "revise: (revise 1 of 2)" "$F" "the blocker is recorded as a revise with its count"
assert_grep "panes holding live work" "$F" "the blocking reason is recorded"
assert_no_grep "proceed:" "$F" "a blocker must never yield a proceed"

# The blocker still blocks when it is the ARCHITECTURE lens that raises it.
brief t1blockarch
mkstub "$TMP/arch-blocker.sh" \
  'PANEL: revise - this contradicts the tracked spec, so the worker would build the wrong thing' \
  'PANEL: proceed-with-notes - minor wording'
FM_INTAKE_CMD="$TMP/arch-blocker.sh" "$ROOT/bin/fm-intake.sh" t1blockarch "$PROJ" >/dev/null 2>&1; code=$?
expect_code 2 "$code" "either lens alone must be able to block"

# --- 3. any escalate -> STILL ESCALATE ---------------------------------------
brief t1esc
mkstub "$TMP/one-escalate.sh" \
  'PANEL: proceed-with-notes - tidy the naming' \
  'PANEL: escalate - this deletes the captain data store; only the captain may authorize it'
FM_INTAKE_CMD="$TMP/one-escalate.sh" "$ROOT/bin/fm-intake.sh" t1esc "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "a single escalate must still exit 3"
F=$(fm_intake_file "$S" t1esc)
[ "$(fm_intake_last "$S" t1esc)" = escalate ] || fail "last decision must be escalate"
assert_no_grep "proceed:" "$F" "an escalate must never yield a proceed"

# --- 4. missing or malformed PANEL line -> STILL ESCALATE (fail closed) -------
brief t1mute
mkstub "$TMP/mute.sh" 'I have opinions but no verdict line.' 'PANEL: proceed - fine'
FM_INTAKE_CMD="$TMP/mute.sh" "$ROOT/bin/fm-intake.sh" t1mute "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "a PANEL-less thinker must still exit 3"
F=$(fm_intake_file "$S" t1mute)
assert_grep "thinker infrastructure failure" "$F" "fail-closed reason recorded for a missing PANEL line"
assert_no_grep "proceed:" "$F" "no proceed may appear on a missing PANEL line"

brief t1hedged
mkstub "$TMP/hedged.sh" 'PANEL: proceed/revise - I could not decide' 'PANEL: proceed - fine'
FM_INTAKE_CMD="$TMP/hedged.sh" "$ROOT/bin/fm-intake.sh" t1hedged "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "a hedged verdict must escalate, not be truncated into a proceed"
F=$(fm_intake_file "$S" t1hedged)
assert_no_grep "proceed:" "$F" "a thinker that could not choose must never yield a proceed"

brief t1malformed
mkstub "$TMP/malformed.sh" 'PANEL: looks-fine - invented verdict word' 'PANEL: proceed - fine'
FM_INTAKE_CMD="$TMP/malformed.sh" "$ROOT/bin/fm-intake.sh" t1malformed "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "a malformed PANEL verdict must escalate, never proceed"
F=$(fm_intake_file "$S" t1malformed)
assert_grep "thinker infrastructure failure" "$F" "a malformed verdict is an infrastructure failure, not a pass"
assert_no_grep "proceed:" "$F" "no proceed may appear on a malformed PANEL line"

pass "T1 severity bar: non-blocking findings proceed with notes; blockers, escalates and malformed verdicts still stop the spawn"
