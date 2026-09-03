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
# TWO VECTORS, because one guard does not cover both:
#   A. the validator's vector - a reference that does not parse at all
#      (`.../pull/1"; touch ./PWNED; :"` trips the `trailing-path` rail). The
#      gate is fm_merge_target_parse_pr_ref, this repo's own single-walk parser.
#   B. the seatbelt's vector - a reference that legitimately PARSES and still
#      carries shell metacharacters, because a query naming no second pull
#      request is accepted (`.../pull/1?x=";touch ./EVIL;"`). The validator
#      alone lets this through; what stops it is emitting the poll script from
#      the PARSED COMPONENTS - a validated owner/name slug and a digit-only
#      number - so no caller byte reaches the generated shell.
#
# Mutation (LEDGER_MUTATE=1): both vectors assert the INJECTION SUCCEEDS - the
# refused payload is expected to arm, and the accepted payload's generated
# script is expected to create ./EVIL when run. A correct implementation
# refuses and stays inert, failing this test.
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
printf '%s\n' "$*" >> "$GH_ARGV_LOG"
printf '%s\n' "${GH_FAKE_STATE:-OPEN}"
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
export GH_ARGV_LOG="$TMP/gh-argv.log"

HONEST="https://github.com/example/repo/pull/7"
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
  [ "$ARM_CODE" -eq 0 ] || fail "MUTATION: arming with an unparseable reference expected to succeed"
  assert_present "$S/inj-a.check.sh" "MUTATION: the poll script was expected to be armed"
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
EXPECTED="state=\$(gh pr view '7' --repo 'example/repo' --json state -q .state 2>/dev/null)
[ \"\$state\" = \"MERGED\" ] && echo \"merged\""
if [ "$MUTATE" != 1 ]; then
  ACTUAL=$(cat "$S/inj-b.check.sh")
  [ "$ACTUAL" = "$EXPECTED" ] || fail \
    "the generated script is not the components-only rendering"$'\n'"--- expected ---"$'\n'"$EXPECTED"$'\n'"--- actual ---"$'\n'"$ACTUAL"
fi


# --- the honest path still works ------------------------------------------
# A guard that refuses everything is not a fix: a valid reference must arm a
# poll that still detects a merged PR and stays silent otherwise.
arm inj-ok "$HONEST"
expect_code 0 "$ARM_CODE" "a valid PR url must arm: $ARM_OUT"
assert_present "$S/inj-ok.check.sh" "the poll script must be armed for a valid url"
assert_grep "pr=$HONEST" "$S/inj-ok.meta" "the pr url must be recorded for a valid url"

if [ "$MUTATE" != 1 ]; then
  OUT_MERGED=$(run_poll inj-ok MERGED)
  [ "$OUT_MERGED" = "merged" ] || fail "the poll must print 'merged' for a MERGED PR (got: '$OUT_MERGED')"
  OUT_OPEN=$(run_poll inj-ok OPEN)
  [ -z "$OUT_OPEN" ] || fail "the poll must print nothing for an OPEN PR (got: '$OUT_OPEN')"
  # The poll names the repository it asks about, rather than leaving `gh` to
  # infer one from whatever clone the watcher happens to be standing in.
  assert_grep "pr view 7 --repo example/repo" "$GH_ARGV_LOG" "the poll must pin the repository it asks about"
fi

pass "fm-pr-check refuses an unparseable PR reference and compiles no caller text into the poll"
