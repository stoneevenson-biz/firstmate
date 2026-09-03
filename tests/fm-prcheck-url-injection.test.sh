#!/usr/bin/env bash
# A PR reference that does not parse must REFUSE rather than be compiled into
# the watcher's poll script - and a reference that DOES parse must contribute
# nothing but its owner/name and its number to that script.
#
# THE DEFECT. bin/fm-pr-check.sh wrote state/<id>.check.sh from an UNQUOTED
# heredoc, so the caller's url was expanded at write time straight into a
# double-quoted word:
#     state=$(gh pr view "<url>" --json state -q .state 2>/dev/null)
# A `"` in the url closed that word and everything after it became shell that
# bin/fm-watch.sh then ran as `timeout N bash <file>` every FM_CHECK_INTERVAL,
# indefinitely, inside the session that holds the helm and merge authority. The
# url is crewmate-supplied by design (AGENTS.md section 7: the crewmate reports
# `done: PR <url>` and firstmate pastes that value in), and nothing validated
# it. The `~/.claude/settings.json` deny rules do not help: the payload runs
# inside a script the watcher invokes, never as a top-level Bash tool call.
#
# THREE VECTORS, because no one guard covers all of them:
#   A. the validator's vector - a reference that does not parse at all
#      (`.../pull/1"; touch ./PWNED; :"` trips the `trailing-path` rail). The
#      gate is fm_merge_target_parse_pr_ref, this repo's own single-walk parser.
#   B. the seatbelt's vector - a reference that legitimately PARSES and still
#      carries shell metacharacters, because a query naming no second pull
#      request is accepted (`.../pull/1?x=";touch ./EVIL;"`). The validator
#      alone lets this through; what stops it is emitting the poll script from
#      the PARSED COMPONENTS, each serialised with `printf %q`, so no caller
#      byte reaches the generated shell whatever the parser later accepts.
#   C. the line rule's vector - a NEWLINE in the query or fragment. The parse
#      strips both before validating anything, so it returns OK, and the raw
#      reference then goes into a line-oriented meta file as `pr=<url>`. Every
#      reader takes `grep '^key=' | tail -1`, so the forged `worktree=` /
#      `harness=` records that follow the newline WIN over the real ones.
#      Neither the parser nor the seatbelt answers this; a control-character
#      rail in fm-pr-check does.
#   D. the line rule's OTHER half - the two characters `\` `n` in the query.
#      There is no control character to refuse, so the rail correctly allows it;
#      what forged the records was writing the value with `echo` under
#      `xpg_echo`, a shell option BASHOPTS carries in from the environment into
#      any non-interactive bash. Refusing a character and writing a value safely
#      are different jobs, and this vector is the one that only the second does.
#   E. the seatbelt itself, asked DIRECTLY. Under the real parser `%q` is only
#      ever handed a digits-only number and a [A-Za-z0-9._/-] slug, so nothing
#      above can tell whether it is there: both calls could be deleted and every
#      other assertion here would still pass. So the rule is exercised at its
#      own seam, bin/fm-poll-lib.sh, with components a loosened parser might
#      emit - a separator, a quote, a space, a command substitution, a newline.
#
# Mutation (LEDGER_MUTATE=1): each vector asserts the INJECTION SUCCEEDS, and
# each proves it by OBSERVING the injected effect rather than by observing that
# something was armed - A runs the generated poll and demands ./PWNED, B runs it
# and demands ./EVIL, C and D demand the forged meta record win, E demands a
# hostile component execute. A correct implementation refuses and stays inert,
# failing this test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

MUTATE=${LEDGER_MUTATE:-}

TMP=$(fm_test_tmproot fm-prcheck-inj)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
export FM_GUARD_GRACE=999999

# A stub `gh` so the generated poll script can be RUN without a network or a
# real binary: it records the argv it was given and answers with the state the
# caller pinned in GH_FAKE_STATE.
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGV_LOG:-/dev/null}"
# Record the --repo VALUE as its own bytes when asked. `$*` joins argv with a
# space, which cannot answer "did this arrive as one argument, unchanged?" -
# the question `printf %q` exists to make answerable.
if [ -n "${GH_REPO_ARG:-}" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--repo" ] && printf '%s' "$a" > "$GH_REPO_ARG"
    prev=$a
  done
fi
printf '%s\n' "${GH_FAKE_STATE:-OPEN}"
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
export GH_ARGV_LOG="$TMP/gh-argv.log"

# A DIFFERENT pull-request number from every other vector here. The argv log
# accumulates across runs, so an honest-path assertion phrased against the
# number a previous vector already polled would pass without this path ever
# producing it - the contamination is silent, and the assertion looks fine.
HONEST="https://github.com/example/repo/pull/12"
NL=$'\n'
# Vector A: does not parse - a `"` opens shell after the pull-request number.
PAYLOAD_A='https://github.com/example/repo/pull/7"; touch ./PWNED; :"'
# Vector B: PARSES (a query naming no second /pull/ is accepted) and still
# carries a quote and a command separator.
PAYLOAD_B='https://github.com/example/repo/pull/7?x=";touch ./EVIL;"'

# arm <task-id> <url> -> sets ARM_OUT / ARM_CODE; the task is fresh each time.
arm() {
  local id=$1 url=$2
  rm -f "$S/$id.meta" "$S/$id.check.sh" "$S/$id.verdict"
  fm_write_meta "$S/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$TMP/wt" "project=$TMP/proj" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_verdict_append "$S" "$id" approve "verified"
  ARM_OUT=$("$ROOT/bin/fm-pr-check.sh" "$id" "$url" 2>&1) && ARM_CODE=0 || ARM_CODE=$?
  return 0
}

# run_poll <task-id> <state> -> runs the generated script the way bin/fm-watch.sh
# does (`bash <file>`), from a scratch cwd, and echoes what it printed.
run_poll() {
  local id=$1 state=$2
  local cwd="$TMP/run-$id-$state"
  mkdir -p "$cwd"
  ( cd "$cwd" && GH_FAKE_STATE="$state" bash "$S/$id.check.sh" 2>/dev/null )
}


# --- vector A: a reference that does not parse is refused ------------------
arm inj-a "$PAYLOAD_A"
if [ "$MUTATE" = 1 ]; then
  # Observe the INJECTION, not merely the arming: a mutation assertion that
  # stops at "a file was written" would pass against a poll that is inert.
  [ "$ARM_CODE" -eq 0 ] || fail "MUTATION: arming with an unparseable reference expected to succeed"
  assert_present "$S/inj-a.check.sh" "MUTATION: the poll script was expected to be armed"
  run_poll inj-a OPEN >/dev/null
  assert_present "$TMP/run-inj-a-OPEN/PWNED" "MUTATION: the generated poll was expected to execute the injected command"
else
  expect_code 1 "$ARM_CODE" "an unparseable PR reference must refuse"
  assert_contains "$ARM_OUT" "REFUSED[pr-ref/" "the refusal must name the rail that stopped it"
  assert_absent "$S/inj-a.check.sh" "no poll script may be written for a refused reference"
  assert_no_grep "pr=" "$S/inj-a.meta" "no pr= may be appended for a refused reference"
fi


# --- vector B: an ACCEPTED reference contributes no shell ------------------
# The validator passes this one; the seatbelt is what makes it inert.
arm inj-b "$PAYLOAD_B"
expect_code 0 "$ARM_CODE" "a parseable reference with a query must still arm: $ARM_OUT"
assert_present "$S/inj-b.check.sh" "the poll script must be armed for an accepted reference"
bash -n "$S/inj-b.check.sh" || fail "the generated poll script is not valid shell"

run_poll inj-b OPEN >/dev/null
if [ "$MUTATE" = 1 ]; then
  assert_present "$TMP/run-inj-b-OPEN/EVIL" "MUTATION: the generated script was expected to execute the injected command"
else
  assert_absent "$TMP/run-inj-b-OPEN/EVIL" "the generated script executed shell from the reference"
  assert_no_grep "touch" "$S/inj-b.check.sh" "the generated script carries a command from the reference"
  assert_no_grep "EVIL" "$S/inj-b.check.sh" "the generated script carries text from the reference"
fi

# Stronger than "no metacharacters": the generated script must be EXACTLY what
# the parsed components determine, so nothing caller-supplied can be in it at
# all. Rendered here from the two components this reference yields.
# `printf %q` leaves a word that needs no quoting bare, which is exactly the
# point: the serialisation is decided by the CONTENT, not by a literal quote
# this file hopes the parser never emits.
#
# Compared with `cmp`, not with `[ "$(cat ...)" = ... ]`. Command substitution
# strips trailing newlines, so a string comparison would accept a file missing
# its terminal newline or carrying extra blank lines and still call the result
# byte-identical. This reads every byte.
if [ "$MUTATE" != 1 ]; then
  # shellcheck disable=SC2016  # a literal format: this is the expected FILE, not a command
  printf 'state=$(gh pr view 7 --repo example/repo --json state -q .state 2>/dev/null)\n[ "$state" = "MERGED" ] && echo "merged"\n' \
    > "$TMP/expected-check.sh"
  cmp -s "$TMP/expected-check.sh" "$S/inj-b.check.sh" || fail \
    "the generated script is not byte-identical to the components-only rendering"$'\n'"--- expected ---"$'\n'"$(cat "$TMP/expected-check.sh")"$'\n'"--- actual ---"$'\n'"$(cat "$S/inj-b.check.sh")"
fi


# --- the honest path still works ------------------------------------------
# A guard that refuses everything is not a fix: a valid reference must arm a
# poll that still detects a merged PR and stays silent otherwise.
arm inj-ok "$HONEST"
expect_code 0 "$ARM_CODE" "a valid PR url must arm: $ARM_OUT"
assert_present "$S/inj-ok.check.sh" "the poll script must be armed for a valid url"
assert_grep "pr=$HONEST" "$S/inj-ok.meta" "the pr url must be recorded for a valid url"

if [ "$MUTATE" != 1 ]; then
  : > "$GH_ARGV_LOG"   # only this path's own records may satisfy the pin below
  OUT_MERGED=$(run_poll inj-ok MERGED)
  [ "$OUT_MERGED" = "merged" ] || fail "the poll must print 'merged' for a MERGED PR (got: '$OUT_MERGED')"
  OUT_OPEN=$(run_poll inj-ok OPEN)
  [ -z "$OUT_OPEN" ] || fail "the poll must print nothing for an OPEN PR (got: '$OUT_OPEN')"
  # The poll names the repository it asks about, rather than leaving `gh` to
  # infer one from whatever clone the watcher happens to be standing in.
  assert_grep "pr view 12 --repo example/repo" "$GH_ARGV_LOG" "the poll must pin the repository it asks about"
fi


# --- vector C: a newline may not become a meta record ----------------------
# The parse strips query and fragment before validating, so this returns OK; the
# refusal has to come from fm-pr-check's own control-character rail.
NEWLINE_REF="https://github.com/example/repo/pull/7?x=${NL}worktree=/tmp/attacker${NL}harness=sh"
arm inj-nl "$NEWLINE_REF"
if [ "$MUTATE" = 1 ]; then
  [ "$ARM_CODE" -eq 0 ] || fail "MUTATION: arming with a newline-bearing reference expected to succeed"
  [ "$(grep '^worktree=' "$S/inj-nl.meta" | tail -1)" = "worktree=/tmp/attacker" ] \
    || fail "MUTATION: the forged worktree= record was expected to win"
else
  expect_code 1 "$ARM_CODE" "a reference carrying a newline must refuse"
  assert_contains "$ARM_OUT" "REFUSED[pr-ref/control-character]" "the newline refusal must name its own rail"
  assert_absent "$S/inj-nl.check.sh" "no poll script may be written for a newline-bearing reference"
  assert_no_grep "pr=" "$S/inj-nl.meta" "no pr= may be appended for a newline-bearing reference"
  [ "$(grep -c '^worktree=' "$S/inj-nl.meta")" = 1 ] \
    || fail "the meta gained a forged worktree= record"
  [ "$(grep '^harness=' "$S/inj-nl.meta" | tail -1)" = "harness=echo" ] \
    || fail "the meta's harness= record was overridden by a forged one"
fi


# --- vector D: `\` `n` is not a control character, and must still not be one --
# The rail correctly allows this reference; what used to forge the records was
# `echo` expanding the escape at write time under xpg_echo. BASHOPTS reaches a
# non-interactive bash, so this runs the real script under the real option.
ESCAPE_REF='https://github.com/example/repo/pull/7?x=\nworktree=/tmp/pwn\nharness=sh'
case "$ESCAPE_REF" in
  *[[:cntrl:]]*) fail "fixture error: vector D must carry NO control character" ;;
esac
rm -f "$S/inj-xpg.meta" "$S/inj-xpg.check.sh" "$S/inj-xpg.verdict"
fm_write_meta "$S/inj-xpg.meta" \
  "window=firstmate:fm-inj-xpg" "worktree=$TMP/wt" "project=$TMP/proj" \
  "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
fm_verdict_append "$S" inj-xpg approve "verified"
# `env`, not a `BASHOPTS=... cmd` prefix: BASHOPTS is READONLY inside a running
# bash, so the prefix form fails the assignment and the command runs with the
# option OFF - a vector that silently proves nothing. Proven on, not assumed:
# a bash that ignored BASHOPTS would make this whole vector vacuous.
env BASHOPTS=xpg_echo bash -c 'shopt -q xpg_echo' \
  || fail "fixture error: BASHOPTS did not enable xpg_echo, so vector D would prove nothing"
env BASHOPTS=xpg_echo "$ROOT/bin/fm-pr-check.sh" inj-xpg "$ESCAPE_REF" >/dev/null 2>&1 \
  || fail "vector D must still ARM - the escape is legal url text, not a refusal"

if [ "$MUTATE" = 1 ]; then
  [ "$(grep '^worktree=' "$S/inj-xpg.meta" | tail -1)" = "worktree=/tmp/pwn" ] \
    || fail "MUTATION: the forged worktree= record was expected to win under xpg_echo"
else
  [ "$(grep -c '^worktree=' "$S/inj-xpg.meta")" = 1 ] \
    || fail "xpg_echo expanded the escape into a forged worktree= record"
  [ "$(grep '^harness=' "$S/inj-xpg.meta" | tail -1)" = "harness=echo" ] \
    || fail "xpg_echo expanded the escape into a forged harness= record"
  [ "$(grep -c '^pr=' "$S/inj-xpg.meta")" = 1 ] \
    || fail "the reference became more than one meta record"
fi


# --- vector E: the seatbelt asked directly, with what a loosened parser emits --
# Nothing above can see whether `%q` is there, because the real parser only ever
# hands it safe components. This asks bin/fm-poll-lib.sh itself.
# shellcheck source=bin/fm-poll-lib.sh
. "$ROOT/bin/fm-poll-lib.sh"

HOSTILE_SEPARATOR='; touch ./OWNED; :'
# shellcheck disable=SC2016  # these are hostile INPUTS; expansion is what they must not get
HOSTILE_COMPONENTS=(
  "$HOSTILE_SEPARATOR"          # a command separator
  "'; touch ./OWNED; :'"        # a single quote, which literal-quoting could not survive
  '" ; touch ./OWNED ; "'       # a double quote, which the original defect turned on
  '$(touch ./OWNED)'            # command substitution
  'a b'                         # a plain space: one word, or two?
  "x${NL}touch ./OWNED"         # a newline inside the component
)

# render_and_run <component> <cwd>: write what the library says for that slug,
# run it with a gh stub that records the --repo argument it actually received.
render_and_run() {
  local component=$1 cwd=$2
  mkdir -p "$cwd"
  fm_poll_render 7 "$component" > "$cwd/poll.sh"
  bash -n "$cwd/poll.sh" || fail "the rendered poll is not valid shell for: $component"
  ( cd "$cwd" && GH_FAKE_STATE=OPEN GH_REPO_ARG="$cwd/repo-arg" GH_ARGV_LOG=/dev/null \
      bash "$cwd/poll.sh" >/dev/null 2>&1 )
}

i=0
for component in "${HOSTILE_COMPONENTS[@]}"; do
  i=$((i + 1))
  cwd="$TMP/seatbelt-$i"
  render_and_run "$component" "$cwd"
  if [ "$MUTATE" = 1 ]; then
    # Only the separator case is asserted under mutation: it is the one that
    # breaks out with NO quoting at all, so it detects deletion of %q without
    # depending on which quoting a mutant might have left behind.
    if [ "$component" = "$HOSTILE_SEPARATOR" ]; then
      assert_present "$cwd/OWNED" "MUTATION: a hostile component was expected to execute"
    fi
  else
    assert_absent "$cwd/OWNED" "a hostile component executed: $component"
    # Stronger than "nothing ran": gh received it as exactly ONE argument, byte
    # for byte. That is what `%q` promises, and a string comparison would not
    # see a lost trailing newline, so this compares bytes.
    assert_present "$cwd/repo-arg" "the poll never reached gh for: $component"
    printf '%s' "$component" > "$cwd/repo-want"
    cmp -s "$cwd/repo-want" "$cwd/repo-arg" || fail \
      "the component did not survive as one exact argument: $component"
  fi
done


pass "fm-pr-check refuses an unparseable PR reference and compiles no caller text into the poll"
