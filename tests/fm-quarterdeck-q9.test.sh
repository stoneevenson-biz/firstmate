#!/usr/bin/env bash
# Q9: the Quarterdeck honours gates/accepted-red.md, structurally, ahead of both
# models.
#
# The defect it freezes: bin/fm-verify.sh did not know accepted-red.md existed.
# Its verifier prompt told the model "every gate must be green; red or unproven
# gates are an automatic reject", which is unsatisfiable in a repo holding a
# declared red - and firstmate's own ledger holds two. CI honoured the baseline;
# the verifier contradicted it, so whether correct work was accepted depended on
# whether the LLM happened to reason about that file on a given run. Correct work
# was rejected non-deterministically, after the build, the pipeline, and CI.
#
# It asserts:
#   - a ledger whose only reds are declared PROCEEDS to the lens and verifier.
#   - an UNDECLARED red rejects, and does so WITHOUT SPENDING EITHER MODEL -
#     the whole point of adjudicating in front of them.
#   - a repo with no gates/ dir proceeds and never escalates. Most projects
#     firstmate ships to have no ledger at all; escalating on a missing file
#     would stop every one of them.
#   - gates/ with no accepted-red.md rejects an undeclared red rather than
#     treating "no declarations" as "nothing to declare".
#   - gates/ with no ledger escalates: the repo declares itself gate-governed
#     and the record of what is proven is gone. Fail closed, not open.
#   - a ledger citing a test file that no longer exists rejects as stale.
#   - the verifier prompt no longer carries a gate rule of its own. Two
#     authorities over one decision is what produced the contradiction.
#
# Mutation (LEDGER_MUTATE=1): the assertions demand the unsafe behaviour - that
# an undeclared red be approved. A correct implementation rejects it.
#
# spec: docs/specs/2026-07-01-agent-os-council.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q9)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

# Both models are stubs that leave a tripwire when they run, so "the ledger was
# adjudicated before either model" is observable rather than asserted.
LENS_TRIP="$TMP/lens-ran"; VERIFY_TRIP="$TMP/verify-ran"
cat > "$TMP/lens.sh" <<SH
#!/usr/bin/env bash
echo ran >> "$LENS_TRIP"
echo "stub lens review"
SH
cat > "$TMP/verify.sh" <<SH
#!/usr/bin/env bash
echo ran >> "$VERIFY_TRIP"
echo "VERDICT: approve - stub"
SH
chmod +x "$TMP/lens.sh" "$TMP/verify.sh"
export FM_LENS_CMD="$TMP/lens.sh"
: > "$TMP/relay.log"
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP/relay.sh"
export FM_RELAY_CMD="$TMP/relay.sh"

# task <id> -> a repo + worktree + ship meta, worktree path echoed
task() {
  local id=$1 repo="$TMP/$1-repo" wt="$TMP/$1-wt"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  mkdir -p "$D/$id"
  fm_write_meta "$S/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$repo" \
    "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
  printf '%s\n' "$wt"
}

# gates <worktree> <declare-the-red>: a ledger with one green, one frozen and
# one red gate, the red declared or not.
gates() {
  local wt=$1 declare_red=$2
  mkdir -p "$wt/gates" "$wt/tests"
  : > "$wt/tests/aa.test.sh"; : > "$wt/tests/bb.test.sh"; : > "$wt/tests/cc.test.sh"
  cat > "$wt/gates/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    { "id": "fx-green",  "status": "green",  "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx-frozen", "status": "frozen", "test_ref": "bash tests/bb.test.sh" },
    { "id": "fx-red",    "status": "red",    "test_ref": "bash tests/cc.test.sh" }
  ]
}
JSON
  if [ "$declare_red" = yes ]; then
    cat > "$wt/gates/accepted-red.md" <<'MD'
# Accepted red gates

- fx-red - a fixture baseline, accepted red on purpose; goes away when the other repo lands.
MD
  else
    cat > "$wt/gates/accepted-red.md" <<'MD'
# Accepted red gates

- fx-some-other-gate - declared, but not the gate that is actually red.
MD
  fi
}

run() { FM_VERIFY_CMD="$TMP/verify.sh" "$ROOT/bin/fm-verify.sh" "$1" >"$TMP/$1.out" 2>&1; }

# --- case A: the only red is declared -> proceed, approve --------------------
WA=$(task a); gates "$WA" yes
run a; codeA=$?
expect_code 0 "$codeA" "a ledger whose only red is DECLARED must not block acceptance;
demanding an all-green ledger is unsatisfiable while a declared baseline exists"
assert_grep "approve:" "$(fm_verdict_file "$S" a)" "the declared-red run reaches an approve"
assert_present "$VERIFY_TRIP" "the verifier must actually run when the ledger is acceptable"
assert_grep "gates: acceptable" "$TMP/a.out" "the acceptable verdict is announced, not silent"

# --- case B: an UNDECLARED red -> reject, before either model ----------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WB=$(task b); gates "$WB" no
run b; codeB=$?

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand that an undeclared red sail through. A correct
  # implementation rejects it, so this fails.
  expect_code 0 "$codeB" "MUTATION: expected an undeclared red gate to be approved"
  assert_grep "approve:" "$(fm_verdict_file "$S" b)" "MUTATION: expected an approve"
else
  expect_code 2 "$codeB" "a red gate that is NOT declared must reject"
  assert_grep "reject: (attempt 1 of 3)" "$(fm_verdict_file "$S" b)" \
    "the gate reject is recorded with an attempt count, like any other reject"
  assert_grep "fx-red" "$(fm_verdict_file "$S" b)" "the reject names the offending gate"
  assert_grep "QUARTERDECK REJECTED" "$TMP/relay.log" "the finding is relayed to the crewmate"
  assert_absent "$LENS_TRIP" \
    "an unacceptable ledger must reject BEFORE the foreign lens - adjudicating
after the models is the expense this stage exists to avoid"
  assert_absent "$VERIFY_TRIP" "an unacceptable ledger must reject BEFORE the verifier"
fi

# --- case C: no gates/ dir -> not applicable, never an escalation ------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
task c >/dev/null   # no gates/ dir in this one
run c; codeC=$?
expect_code 0 "$codeC" "a repo with no gates/ dir must proceed normally"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" c)" \
  "a missing gates/ dir must never escalate - most projects have no ledger at all"
assert_present "$VERIFY_TRIP" "with no gates/ dir the verifier still runs"

# --- case D: gates/ but no accepted-red.md -> the red is undeclared ----------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WD=$(task d); gates "$WD" yes; rm -f "$WD/gates/accepted-red.md"
run d; codeD=$?
expect_code 2 "$codeD" "with no accepted-red.md, no red is declared, so a red rejects"
assert_absent "$VERIFY_TRIP" "the no-declarations reject also precedes the verifier"

# --- case E: gates/ but no ledger -> escalate, fail closed ------------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WE=$(task e); gates "$WE" yes; rm -f "$WE/gates/ledger.json"
run e; codeE=$?
expect_code 3 "$codeE" "gates/ with no ledger must escalate, never approve"
assert_grep "escalate:" "$(fm_verdict_file "$S" e)" "the missing ledger is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" e)" "an unprovable ledger must never approve"

# --- case F: a ledger citing a test file that is gone -> stale, reject -------
#
# This proves only that the ledger is not referencing tests that no longer
# exist. It does NOT prove any test passes - that is CI's job, and re-running
# the suite here would duplicate it at the most expensive moment.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WF=$(task f); gates "$WF" yes; rm -f "$WF/tests/aa.test.sh"
run f; codeF=$?
expect_code 2 "$codeF" "a ledger claiming a gate whose test file is gone is stale, and rejects"
assert_grep "fx-green" "$(fm_verdict_file "$S" f)" "the stale reject names the gate"
assert_grep "tests/aa.test.sh" "$(fm_verdict_file "$S" f)" "the stale reject names the missing test"

# --- case G: the prompt no longer carries a gate rule of its own -------------
#
# Comments are stripped first: the file's header deliberately QUOTES the deleted
# instruction to record what went wrong, and that history must not be mistaken
# for the instruction still being live. Only what the model actually reads
# counts.
V="$ROOT/bin/fm-verify.sh"
BODY="$TMP/verify-body.sh"
grep -v '^[[:space:]]*#' "$V" > "$BODY"
assert_no_grep "every gate must be" "$BODY" \
  "the verifier prompt must not state its own gate rule; the classifier owns that
decision, and a second authority over it is what produced the contradiction"
assert_no_grep "run: bash gates/verify.sh" "$BODY" \
  "the prompt must not tell the verifier to run gates/verify.sh - ledger verify
re-runs every gate and rewrites the ledger inside the crewmate's worktree"
assert_grep "fm-gates-lib.sh" "$BODY" "fm-verify must cite the classifier"

# The verifier prompt is an UNQUOTED heredoc inside a command substitution, so
# bash re-scans its body at run time: a lone apostrophe opens a quote that never
# closes and the script dies with "unexpected EOF" pointing at a line well past
# the heredoc. bash -n does not catch it. Writing the possessive form of "repo"
# while editing this stage did exactly that - fm-verify exited 2 mid-run, and it
# surfaced only because Q6 happened to exercise that path.
# shellcheck disable=SC2016 # the \$ is a literal in the sed address, not an expansion
APOS=$(sed -n '/^PROMPT=\$(cat <<EOF$/,/^EOF$/p' "$V" | grep -c "'" || true)
expect_code 0 "$APOS" "the verifier prompt heredoc must contain no apostrophe -
it is unquoted inside a command substitution, so bash re-scans it and an
unmatched quote kills fm-verify at run time, invisibly to bash -n"

pass "Q9 Quarterdeck honours declared-red gates, ahead of both models"
