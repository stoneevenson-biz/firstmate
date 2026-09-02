#!/usr/bin/env bash
# GATE h11 - `doctrine` renders the rules from the constants that enforce them.
#
# WHAT THE VERB IS FOR. An agent should learn this script's rules from the
# BINARY, not from prose somewhere else that has drifted. That only works if the
# output is rendered from the enforcing values. A heredoc of hand-written rules
# beside the code is a second copy of the rule, and the second copy is the one
# that goes stale - the `<project>/<work>` convention stayed written down after
# herdr had started refusing it with invalid_agent_name, which is precisely how
# an agent ends up confidently naming a pane something herdr will not accept.
#
# So the gate is not "doctrine prints something about names". It is: the string
# doctrine prints IS the string fm_herdr_name_valid validates with, proven by
# changing the constant and watching both move together, and by counting how
# many times that literal appears in the script's code at all.
#
# Mutation (LEDGER_MUTATE=1): the library is copied with doctrine's regex
# argument replaced by a hardcoded literal - the exact second copy this gate
# exists to forbid. The linkage case then sees doctrine print the old rule while
# the validator applies the new one, and the single-copy count goes to two.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h11)
LIB="$ROOT/bin/fm-herdr.sh"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  LIB="$TMP_ROOT/mutated-fm-herdr.sh"
  # shellcheck disable=SC2016  # a literal sed pattern: the point is NOT to expand it
  sed 's/"\$fm_herdr_name_re"/"^[a-z][a-z0-9_-]{0,31}$"/' \
    "$ROOT/bin/fm-herdr.sh" > "$LIB"
fi

FB=$(fm_herdr_fake_server "$TMP_ROOT")
CALLS="$TMP_ROOT/calls"; export CALLS

# shellcheck source=bin/fm-herdr.sh
. "$LIB"

# --- the linkage: one constant, two readers ---------------------------------

# THE CASE THE WHOLE VERB RESTS ON. Change the rule, and both the check and the
# rendering must follow it. If doctrine keeps printing the old string while
# fm_herdr_name_valid applies the new one, the verb is worse than nothing: it
# is a confident, wrong answer.
# The override runs in a CHILD PROCESS, not a subshell of this one: the constant
# has to be changed for the probe and unchanged for every case after it, and a
# fresh `bash -c` that sources the library cannot leak either way. (It sources
# the path as "$1" rather than "$0", which is what keeps the library's
# executed-not-sourced guard from running the CLI.)
probe() {  # <shell-body>
  bash -c '. "$1"; shift; eval "$@"' _ "$LIB" "$1"
}

test_doctrine_follows_the_constant_the_check_reads() {
  local out
  out=$(probe 'fm_herdr_name_re="^zz[a-z]*$"; fm_herdr_doctrine')
  assert_contains "$out" '^zz[a-z]*$' "doctrine did not follow the constant the check reads"
  assert_not_contains "$out" '^[a-z][a-z0-9_-]{0,31}$' \
    "doctrine printed a hardcoded regex beside the constant - the second copy this verb exists to kill"
  # And the check really did move with it, so the pair is genuinely linked
  # rather than both being wrong in the same direction.
  probe 'fm_herdr_name_re="^zz[a-z]*$"; fm_herdr_name_valid zzabc' \
    || fail "the check did not follow the constant either"
  ! probe 'fm_herdr_name_re="^zz[a-z]*$"; fm_herdr_name_valid afs-x' \
    || fail "the check ignored the constant"
  pass "doctrine: renders the same constant fm_herdr_name_valid validates with"
}

# The exactness requirement, stated plainly: the literal string, character for
# character, not a prose paraphrase of it.
test_doctrine_contains_the_exact_regex_name_validates_with() {
  local out
  out=$(fm_herdr_doctrine)
  assert_contains "$out" "$fm_herdr_name_re" \
    "doctrine does not contain the exact regex fm_herdr_name_valid validates with"
  pass "doctrine: contains the exact regex string \`name\` validates with"
}

# THE STRUCTURAL HALF. A linkage test can be satisfied by a script that reads the
# constant AND also carries a stale literal somewhere else that some other reader
# uses. The rule has one home: outside comments, the regex literal appears once.
test_the_regex_literal_appears_once_in_code() {
  local n
  n=$(grep -v '^[[:space:]]*#' "$LIB" | grep -cF -- "$fm_herdr_name_re")
  [ "$n" = 1 ] || fail "the name regex literal appears $n times in code; the rule must have exactly one home"
  pass "doctrine: the regex literal has exactly one home in the code"
}

# --- the other two constants ------------------------------------------------

test_doctrine_renders_the_resolved_width_cap() {
  local out long toolong n=0
  out=$(fm_herdr_doctrine)
  assert_contains "$out" "$fm_herdr_name_max" "doctrine does not render the width cap"
  # Rendered as a NUMBER is not enough: the cap it prints must be the cap the
  # check applies, so the proof rows are checked against the validator itself.
  long=""; while [ "$n" -lt "$fm_herdr_name_max" ]; do long="${long}a"; n=$((n + 1)); done
  toolong="${long}a"
  fm_herdr_name_valid "$long"    || fail "a name at the rendered cap is refused by the check"
  ! fm_herdr_name_valid "$toolong" || fail "a name one over the rendered cap is accepted by the check"
  assert_contains "$out" "accepted" "doctrine's proof section renders no verdicts"
  assert_contains "$out" "refused"  "doctrine's proof section renders no refusals"
  pass "doctrine: renders the resolved width cap, and proves it against the check"
}

test_doctrine_renders_the_tier_vocabulary() {
  local out tier
  out=$(fm_herdr_doctrine)
  for tier in $fm_herdr_tiers; do
    assert_contains "$out" "$tier" "doctrine omits the '$tier' tier"
  done
  assert_contains "$out" "$fm_herdr_pane_id_re" \
    "doctrine does not render the pane-id shape the resolver actually matches"
  pass "doctrine: renders the tier vocabulary and the pane-id shape from the constants"
}

# A VOCABULARY OF WORDS IS NOT A CONSTANT. Looping the rendering over the same
# variable the test loops over proves only that the two agree with each other, so
# a tier could name an object this script never touches and h11 would stay green.
# Every tier must be a herdr object the script actually ADDRESSES - `herdr <tier>
# <verb>` appears in it. (A subset, not an equality: `agent` is a herdr noun this
# script addresses constantly and is deliberately NOT a tier, because an agent
# lives in a pane rather than containing one.)
test_every_tier_is_an_object_this_script_addresses() {
  local tier
  for tier in $fm_herdr_tiers; do
    grep -q "herdr $tier " "$LIB" \
      || fail "'$tier' is rendered as a tier but this script never addresses \`herdr $tier\`"
  done
  pass "doctrine: every tier named is a herdr object the script actually addresses"
}

# --- the verb itself --------------------------------------------------------

# An agent asking what the rules are is the one question that must always have
# an answer, so doctrine reads nothing and touches nothing.
test_doctrine_needs_no_server_and_touches_nothing() {
  local out rc=0
  : > "$CALLS"
  out=$(PATH="$(fm_herdr_path_without_binary herdr)" FM_HOME="$TMP_ROOT" \
          bash "$LIB" doctrine 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "doctrine failed with no herdr on PATH (exit $rc): $out"
  assert_contains "$out" "$fm_herdr_name_re" "the doctrine verb did not render the rules"
  [ ! -s "$CALLS" ] || fail "doctrine called herdr: $(cat "$CALLS")"
  pass "doctrine: answers with no server, and calls herdr not once"
}

test_the_cli_exposes_doctrine_as_a_verb() {
  local out
  out=$(PATH="$FB:$PATH" FM_HOME="$TMP_ROOT" bash "$LIB" doctrine 2>&1)
  assert_contains "$out" "TIERS"    "the doctrine verb renders no tier section"
  assert_contains "$out" "NAMES"    "the doctrine verb renders no naming section"
  assert_contains "$out" "MUTATION" "the doctrine verb does not say which verbs mutate"
  pass "doctrine: reachable as \`fm-herdr.sh doctrine\`"
}

test_doctrine_follows_the_constant_the_check_reads
test_doctrine_contains_the_exact_regex_name_validates_with
test_the_regex_literal_appears_once_in_code
test_doctrine_renders_the_resolved_width_cap
test_doctrine_renders_the_tier_vocabulary
test_every_tier_is_an_object_this_script_addresses
test_doctrine_needs_no_server_and_touches_nothing
test_the_cli_exposes_doctrine_as_a_verb
