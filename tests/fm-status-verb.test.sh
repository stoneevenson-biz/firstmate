#!/usr/bin/env bash
# status-verb: a crewmate whose direct redirect is refused can still report.
#
# The defect this closes was observed, not imagined. A crewmate was told by its
# own brief to report with:
#
#     echo "done: ..." >> /Users/stoneevenson/firstmate/state/<id>.status
#
# and every attempt was refused, five times across one task, because the global
# permission profile denies Edit(~/firstmate/**) and the harness classifies a
# shell redirect into that tree as an edit. The status file was never created,
# so no status line from that task ever reached firstmate. The work was done and
# the supervisor could not see it - the crewmate/firstmate channel was silently
# dead for the whole task.
#
# The fix is to make reporting a VERB rather than a raw redirect: the append
# happens INSIDE bin/fm-status.sh, which the profile permits, instead of in a
# command line the profile refuses.
#
# HOW THIS IS TESTED WITHOUT THE HARNESS. A test cannot invoke the real
# permission layer, so the policy is modelled exactly as it behaves: a predicate
# over the command string that refuses any command redirecting into the home.
# The gate then proves three things together, which is what makes it meaningful:
#
#   1. the modelled policy REFUSES the old redirect form  (the model has teeth)
#   2. the modelled policy PERMITS the verb form          (the verb is reachable)
#   3. running the verb actually appends the line         (it really reports)
#
# Without (1) the model would be vacuous; without (3) a permitted no-op would
# pass. All three, or nothing.
#
# Mutation (LEDGER_MUTATE=1): the brief assertions are inverted to demand the
# old `echo >>` form. A brief that has been fixed to teach the verb then fails,
# which keys the gate to the guidance crewmates actually receive rather than
# only to the script existing.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS_SH="$ROOT/bin/fm-status.sh"
assert_present "$STATUS_SH" "bin/fm-status.sh must exist"

TMP=$(fm_test_tmproot fm-status-verb)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects/demo"

# --- the command crewmates actually receive ---------------------------------
#
# The form under test is DERIVED from a real generated brief, never restated
# here. A hand-written copy drifts the moment the emitted command changes - and
# a stale copy is exactly what made the home-routing defect invisible one level
# down. The brief is scaffolded into the modelled protected home, so the policy
# below judges the same command, targeting the same home, that a crewmate under
# the real profile would be handed.
BRIEF_SH="$ROOT/bin/fm-brief.sh"
assert_present "$BRIEF_SH" "bin/fm-brief.sh must exist"

FM_HOME="$HOME_DIR" bash "$BRIEF_SH" task-1 demo >/dev/null 2>&1 \
  || fail "fm-brief.sh must scaffold a ship brief"
GEN="$HOME_DIR/data/task-1/brief.md"
assert_present "$GEN" "the generated brief must exist"

# One backticked command per status line; take the first and strip the ticks.
VERB_FORM=$(grep -m1 -F 'fm-status.sh' "$GEN" | sed -n 's/^[^`]*`\(.*\)`[^`]*$/\1/p')
[ -n "$VERB_FORM" ] \
  || fail "could not extract the status command from the generated brief - this gate must model the emitted form, not a restatement of it"

# --- the modelled permission policy -----------------------------------------
#
# Mirrors deny: Edit(~/firstmate/**) as the harness applies it to Bash - a
# command whose text redirects into the protected home is refused; running a
# script that happens to write there is not.
policy_permits() {
  case "$1" in
    *">>"*"$HOME_DIR"*|*">"*"$HOME_DIR"*) return 1 ;;
    *) return 0 ;;
  esac
}

REDIRECT_FORM="echo \"done: via redirect\" >> $HOME_DIR/state/task-1.status"

# 1. the model has teeth: the old form is refused
if policy_permits "$REDIRECT_FORM"; then
  fail "the modelled policy must REFUSE a direct redirect into the home - otherwise this gate proves nothing"
fi

# 2. the emitted verb form is permitted by the same policy
policy_permits "$VERB_FORM" \
  || fail "the emitted verb form must be PERMITTED by the same policy that refuses the redirect: $VERB_FORM"

# 3. and it actually reports. The emitted command itself is run - with only its
#    message placeholder filled in - exactly as a crewmate under the real
#    profile would run it. The ambient environment names a DIFFERENT home, so a
#    command that leaned on what it inherited would land in the wrong state dir
#    and be caught here rather than in production.
mkdir -p "$TMP/wrong"
RUN_FORM=${VERB_FORM/'"{state}: {one short line}"'/"'done: via the verb'"}
[ "$RUN_FORM" != "$VERB_FORM" ] \
  || fail "the emitted status command no longer carries the {state} message placeholder this gate substitutes"
FM_HOME="$TMP/wrong" FM_STATE_OVERRIDE="$TMP/wrong" eval "$RUN_FORM" \
  || fail "the emitted status command must exit 0 on a normal append"

STATUS="$HOME_DIR/state/task-1.status"
assert_present "$STATUS" "the verb must create the status file when it is absent"
assert_absent "$TMP/wrong/task-1.status" \
  "the emitted command must pin its own home, not follow the ambient environment"
assert_grep "done: via the verb" "$STATUS" "the reported line must reach the status file"

# Appends, never truncates - a second report must not lose the first.
FM_HOME="$HOME_DIR" bash "$STATUS_SH" task-1 "working: second line" \
  || fail "a second append must succeed"
assert_grep "done: via the verb" "$STATUS" "an earlier line must survive a later append"
assert_grep "working: second line" "$STATUS" "the later line must be recorded too"
[ "$(wc -l < "$STATUS")" -eq 2 ] \
  || fail "expected exactly 2 status lines, got $(wc -l < "$STATUS")"

# One line in, one line out: an embedded newline must not forge extra records,
# since each line is a separate wake for firstmate.
FM_HOME="$HOME_DIR" bash "$STATUS_SH" task-1 "blocked: one"$'\n'"forged: two" \
  || fail "a message containing a newline must still be accepted"
[ "$(wc -l < "$STATUS")" -eq 3 ] \
  || fail "an embedded newline must not forge extra status records (got $(wc -l < "$STATUS") lines)"
# The text is flattened onto the one line, not deleted - what must not happen is
# it starting a record of its own, since firstmate reads each line as a report.
grep -q '^forged: two' "$STATUS" \
  && fail "a forged second record must not begin its own line"
assert_grep "blocked: one forged: two" "$STATUS" \
  "the newline must be flattened into the single reported line, not dropped"

# --- FM_HOME resolution, the same way the rest of bin/ does it ---------------
OTHER="$TMP/other"
mkdir -p "$OTHER/state"
FM_HOME="$OTHER" bash "$STATUS_SH" task-9 "done: other home" \
  || fail "the verb must honour FM_HOME"
assert_present "$OTHER/state/task-9.status" "FM_HOME must select which home is written"
assert_absent "$HOME_DIR/state/task-9.status" "the wrong home must not be written"

# FM_STATE_OVERRIDE is honoured by 23 other bin/ scripts; this must not be the
# one that ignores it.
OVR="$TMP/override"
mkdir -p "$OVR"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$OVR" bash "$STATUS_SH" task-2 "done: overridden" \
  || fail "the verb must honour FM_STATE_OVERRIDE"
assert_present "$OVR/task-2.status" "FM_STATE_OVERRIDE must select the state dir"

# --- refusals are loud ------------------------------------------------------
FM_HOME="$HOME_DIR" bash "$STATUS_SH" 2>/dev/null \
  && fail "a missing id and message must be refused"
FM_HOME="$HOME_DIR" bash "$STATUS_SH" task-1 "" 2>/dev/null \
  && fail "an empty message must be refused rather than writing a blank wake"
FM_HOME="$HOME_DIR" bash "$STATUS_SH" "../escape" "done: nope" 2>/dev/null \
  && fail "a task id containing a path separator must be refused"
assert_absent "$TMP/escape.status" "a traversing id must not write outside the state dir"

# --- the guidance crewmates actually receive --------------------------------
#
# The script existing changes nothing if every generated brief still teaches the
# form that gets refused. This is the half that closes the defect. It reads the
# same $GEN the executed command was extracted from, so the guidance and the
# thing this gate proved are one artifact rather than two that can diverge.
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  assert_grep 'echo "{state}' "$GEN" \
    "MUTATION: expected the brief to still teach the refused redirect form"
else
  assert_grep "fm-status.sh" "$GEN" \
    "the generated brief must teach the verb, or the script helps nobody"
  assert_no_grep 'echo "{state}: {one short line}" >>' "$GEN" \
    "the generated brief must NOT teach the redirect form that gets refused"
fi

pass "status reporting is a verb a refused crewmate can still use"
