#!/usr/bin/env bash
# T1 (path): a merge lands in the repository that was NAMED, never in the one
# the tool would infer.
#
# The defect it freezes. `~/firstmate` carries two GitHub remotes - `origin`
# (stoneevenson-biz/firstmate, the captain's fork) and `upstream`
# (kunchenguid/firstmate, a public project). `gh`-shaped tooling does not merge
# "here"; it resolves a BASE repo from the remote set and prefers the PARENT for
# PR operations. On 2026-08-29 firstmate ran `gh-axi pr merge 5` with no repo
# argument in that clone and it resolved to UPSTREAM. It was a no-op only
# because that PR had merged months earlier; had it been open, a stranger's
# contribution would have been merged into open source under the captain's name.
#
# THE FIXTURE POINTS THE INFERENCE AT THE WRONG REMOTE ON PURPOSE. The stub
# `gh-axi` records `merged-into=$FM_TEST_GH_INFERRED` - upstream - whenever no
# `--repo` reaches it, and case 0 proves that is what an unpinned call does. So
# every "targets origin" assertion below is a real claim about the code under
# test, not an artefact of a stub that had nowhere else to go: before
# bin/fm-merge-pr.sh existed, the merge command carried no repository at all and
# these assertions read `kunchenguid/firstmate`.
#
# NO REAL MERGE IS EVER RUN. The boundary is stubbed: a fake `gh-axi` first on
# PATH that appends its argv to a record file and exits. Nothing in this suite
# reaches the network, and the fixture's "remotes" are URLs only - never fetched.
#
# It asserts:
#   0. control: an unpinned `gh-axi pr merge 5` lands in UPSTREAM (the red).
#   1. two remotes, PR given as a URL naming origin -> the command carries
#      `--repo stoneevenson-biz/firstmate` and lands there.
#   2. two remotes, bare number + `--remote origin` -> same, resolved from
#      origin's own URL.
#   3. two remotes, bare number, no choice -> REFUSES, names BOTH remotes with
#      their owner/name, and never invokes the merge tool at all.
#   4. a single-remote clone still merges normally, and still passes `--repo`.
#   5. `--repo` is honoured verbatim; a malformed one refuses.
#   6. a target that is not origin merges once affirmed with --allow-non-origin
#      (it was named) but says so loudly, naming the remote it belongs to.
#   6b. a repo flag smuggled in after `--` REFUSES in EVERY spelling - detached,
#      inline, ATTACHED (-Rowner/repo) and CLUSTERED (-dR owner/repo) - because
#      gh-axi keeps the LAST -R/--repo and passthrough would override the pin.
#   7. `--dry-run` prints the exact command and runs nothing.
#   8. the real call path: project and PR read from state/<id>.meta.
#
# Mutation (LEDGER_MUTATE=1): case 3 asserts the UNSAFE behaviour - that a bare
# number in a two-remote clone merges anyway, landing wherever the tool inferred.
# A correct merge path refuses, so the assertion fails.
#
# spec: docs/specs/2026-08-31-merge-target-pin.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-merge-t1-pinned)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
fm_git_identity

ORIGIN_SLUG=stoneevenson-biz/firstmate
UPSTREAM_SLUG=kunchenguid/firstmate

# --- the fixture: one clone with BOTH remotes, exactly like ~/firstmate ------
BOTH="$TMP/both"
fm_git_init_commit "$BOTH"
git -C "$BOTH" remote add origin "git@github.com:$ORIGIN_SLUG.git"
git -C "$BOTH" remote add upstream "https://github.com/$UPSTREAM_SLUG.git"

SOLO="$TMP/solo"
fm_git_init_commit "$SOLO"
git -C "$SOLO" remote add origin "git@github.com:$ORIGIN_SLUG.git"

# --- stub the boundary: a gh-axi that records instead of merging -------------
FAKE=$(fm_fakebin "$TMP")
cat > "$FAKE/gh-axi" <<'SH'
#!/usr/bin/env bash
# Models gh's base-repo resolution: absent an explicit repository, a PR
# operation in a fork resolves to the PARENT. Pointed at the WRONG remote on
# purpose - that inference is the defect under test.
repo=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[i]}" in
    --repo|-R) repo="${args[$((i + 1))]:-}" ;;
    --repo=*)  repo="${args[i]#--repo=}" ;;
    -R=*)      repo="${args[i]#-R=}" ;;
  esac
  i=$((i + 1))
done
[ -n "$repo" ] || repo="${FM_TEST_GH_INFERRED:-INFERRED-NOTHING}"
{
  printf 'argv=%s\n' "$*"
  printf 'merged-into=%s\n' "$repo"
} >> "$FM_TEST_GH_RECORD"
SH
chmod +x "$FAKE/gh-axi"
PATH="$FAKE:$PATH"; export PATH
export FM_TEST_GH_INFERRED="$UPSTREAM_SLUG"

REC="$TMP/gh.log"
export FM_TEST_GH_RECORD="$REC"
reset_record() { : > "$REC"; }
record() { cat "$REC"; }

MERGE="$ROOT/bin/fm-merge-pr.sh"

# --- 0. control: the inference really does point at the wrong remote --------
reset_record
gh-axi pr merge 5
assert_contains "$(record)" "merged-into=$UPSTREAM_SLUG" \
  "control: an unpinned merge lands in upstream - this is the red the gate freezes"
pass "control: an unpinned 'gh-axi pr merge 5' resolves to $UPSTREAM_SLUG"

# --- 1. two remotes, PR URL naming origin -> pinned to origin ---------------
reset_record
out=$("$MERGE" t1a "https://github.com/$ORIGIN_SLUG/pull/5" --project "$BOTH" 2>&1); code=$?
expect_code 0 "$code" "a PR URL names its own repo and must merge: $out"
assert_contains "$(record)" "--repo $ORIGIN_SLUG" "the merge command must carry --repo"
assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the merge must land in origin"
assert_not_contains "$(record)" "merged-into=$UPSTREAM_SLUG" "the inference must never decide"
assert_contains "$(record)" "argv=pr merge 5 " "the PR number is read out of the URL"
pass "two remotes + PR URL: merge is pinned to $ORIGIN_SLUG, not the inferred $UPSTREAM_SLUG"

# --- 2. two remotes, bare number + --remote origin -> resolved from its URL --
reset_record
out=$("$MERGE" t1b 5 --project "$BOTH" --remote origin 2>&1); code=$?
expect_code 0 "$code" "--remote origin is an explicit choice and must merge: $out"
assert_contains "$(record)" "--repo $ORIGIN_SLUG" "--remote origin resolves to origin's own owner/name"
assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the merge must land in origin"
pass "two remotes + --remote origin: target read from the remote URL, passed explicitly"

# --- 3. two remotes, bare number, no choice -> refuse, naming both ----------
reset_record
out=$("$MERGE" t1c 5 --project "$BOTH" 2>&1); code=$?
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  expect_code 0 "$code" "MUTATION: a bare number in a two-remote clone expected to merge anyway"
  assert_contains "$(record)" "merged-into=" "MUTATION: expected the merge tool to have been invoked"
else
  expect_code 1 "$code" "a bare number in a two-remote clone must refuse"
  assert_contains "$out" "AMBIGUOUS" "the refusal must say the target is ambiguous"
  assert_contains "$out" "origin" "the refusal must name the origin remote"
  assert_contains "$out" "$ORIGIN_SLUG" "the refusal must name origin's repository"
  assert_contains "$out" "upstream" "the refusal must name the upstream remote"
  assert_contains "$out" "$UPSTREAM_SLUG" "the refusal must name upstream's repository"
  assert_contains "$out" "--remote" "the refusal must say how to disambiguate"
  [ ! -s "$REC" ] || fail "a refused merge must never invoke the merge tool: $(record)"
  pass "two remotes + bare number: refuses, names both remotes, and runs no merge"
fi

# --- 4. a single-remote clone still merges normally -------------------------
reset_record
out=$("$MERGE" t1d 7 --project "$SOLO" 2>&1); code=$?
expect_code 0 "$code" "a single-remote clone must still merge: $out"
assert_contains "$(record)" "--repo $ORIGIN_SLUG" "even the unambiguous case passes --repo rather than relying on inference"
assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the single-remote merge lands in that remote"
assert_contains "$(record)" "argv=pr merge 7 " "the bare number is passed through"
pass "single remote: merges normally, still explicitly pinned"

# --- 5. --repo is verbatim; a malformed one refuses -------------------------
#
# A repository that is not this clone's origin now needs --allow-non-origin as
# well: being NAMED establishes that nothing was inferred, and the second word
# establishes that leaving origin was meant. --repo is still verbatim.
reset_record
out=$("$MERGE" t1e 5 --project "$BOTH" --repo other-owner/other-repo --allow-non-origin 2>&1); code=$?
expect_code 0 "$code" "an explicit --repo must be honoured: $out"
assert_contains "$(record)" "merged-into=other-owner/other-repo" "--repo is used verbatim"

reset_record
out=$("$MERGE" t1e2 5 --project "$BOTH" --repo "not a slug" 2>&1); code=$?
expect_code 1 "$code" "a malformed --repo must refuse"
assert_contains "$out" "REFUSED" "a malformed --repo refuses out loud"
[ ! -s "$REC" ] || fail "a malformed --repo must never reach the merge tool"
pass "--repo: honoured verbatim, refused when malformed"

# --- 6. a non-origin target merges only when affirmed, and never silently ---
reset_record
out=$("$MERGE" t1f "https://github.com/$UPSTREAM_SLUG/pull/5" --project "$BOTH" --allow-non-origin 2>&1); code=$?
expect_code 0 "$code" "a named and affirmed upstream target is legitimate and must merge: $out"
assert_contains "$(record)" "merged-into=$UPSTREAM_SLUG" "the named upstream target is used"
assert_contains "$out" "NOT this clone's origin" "merging outside origin must be announced"
assert_contains "$out" "upstream" "the announcement names the remote the target belongs to"
pass "non-origin target: merges because it was named AND affirmed, and says so loudly"

# --- 6b. passthrough may not smuggle a target past the pin ------------------
#
# gh-axi scans EVERY -R/--repo and keeps the LAST, so an unfiltered passthrough
# would silently win over the pin while stderr still announced the resolved
# target - the same defect this whole path exists to close, wearing the script's
# own advertised feature as a disguise.
for smuggle in "--repo other/repo" "--repo=other/repo" "-R other/repo" "-R=other/repo" \
               "-Rother/repo" "-dR other/repo" "-dRother/repo"; do
  reset_record
  # shellcheck disable=SC2086  # deliberate word-splitting: each case is an argv
  out=$("$MERGE" t1j 5 --project "$SOLO" -- $smuggle 2>&1); code=$?
  expect_code 1 "$code" "a repo flag after -- must refuse: $smuggle"
  assert_contains "$out" "REFUSED" "the refusal is loud: $smuggle"
  [ ! -s "$REC" ] || fail "a smuggled repo flag must never reach the merge tool: $(record)"
done

reset_record
out=$("$MERGE" t1k 5 --project "$SOLO" -- --squash --delete-branch 2>&1); code=$?
expect_code 0 "$code" "ordinary passthrough options still work: $out"
assert_contains "$(record)" "--repo $ORIGIN_SLUG" "the pin survives passthrough options"
assert_contains "$(record)" "--squash --delete-branch" "passthrough options reach the tool"
pass "passthrough: merge options pass through, a repo flag is refused before anything runs"

# --- 7. --dry-run runs nothing ---------------------------------------------
reset_record
out=$("$MERGE" t1g 5 --project "$BOTH" --remote origin --dry-run 2>/dev/null); code=$?
expect_code 0 "$code" "--dry-run must succeed"
assert_contains "$out" "gh-axi pr merge 5 --repo $ORIGIN_SLUG" "--dry-run prints the exact pinned command"
[ ! -s "$REC" ] || fail "--dry-run must not invoke the merge tool"
pass "--dry-run: prints the pinned command, merges nothing"

# --- 8. the real call path: project and PR come from the meta ---------------
reset_record
fm_write_meta "$S/t1h.meta" \
  "window=firstmate:fm-t1h" "worktree=$TMP/wt" "project=$BOTH" \
  "harness=echo" "kind=ship" "mode=direct-PR" "yolo=off" \
  "pr=https://github.com/$ORIGIN_SLUG/pull/11"
out=$("$MERGE" t1h 2>&1); code=$?
expect_code 0 "$code" "a task with a recorded PR url must merge: $out"
assert_contains "$(record)" "--repo $ORIGIN_SLUG" "the meta path is pinned too"
assert_contains "$(record)" "argv=pr merge 11 " "the PR number comes from the recorded url"

fm_write_meta "$S/t1i.meta" \
  "window=firstmate:fm-t1i" "worktree=$TMP/wt" "project=$BOTH" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
out=$("$MERGE" t1i 5 2>&1); code=$?
expect_code 1 "$code" "a local-only task has no PR and must be refused here"
assert_contains "$out" "fm-merge-local.sh" "the refusal points at the local merge path"
pass "meta path: project and PR resolved from state/<id>.meta, local-only refused"
