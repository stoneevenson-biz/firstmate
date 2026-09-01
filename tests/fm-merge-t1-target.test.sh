#!/usr/bin/env bash
# T1 (rule): fm_merge_target is the single, pure, fail-closed owner of "which
# GitHub repository does this merge land in?".
#
# The defect it freezes: nothing owned that question at all. Firstmate ran
# `gh-axi pr merge <n>` by hand, and `gh`-shaped tooling answers it itself by
# resolving a base repo from the clone's remote set - preferring the PARENT for
# PR operations in a fork. In `~/firstmate`, which carries `origin`
# (stoneevenson-biz/firstmate) and `upstream` (kunchenguid/firstmate), that
# answered "upstream" on 2026-08-29.
#
# It asserts, in one place:
#   - PRECEDENCE: --repo, then --remote, then a full PR URL, then a sole remote.
#     Each earlier form wins over every later one, so a caller who named a
#     repository is never overridden by one who merely stands in a clone.
#   - AMBIGUITY IS A STOP: two or more remotes with no explicit choice is
#     AMBIGUOUS and every remote is named, including one whose URL is not a
#     GitHub repository at all (shown raw, so the reader sees why it was no
#     help). It does NOT quietly prefer `origin`: the near-miss happened in a
#     clone that had one, so a second remote means the caller says which.
#   - a SOLE remote is not a choice between candidates and resolves.
#   - every URL form git actually stores parses to the same owner/name, and a
#     non-GitHub URL parses to nothing rather than to a guess.
#   - THE NUMBER AND THE REPOSITORY COME FROM ONE PARSE: a ref containing
#     `/pull/<digits>` that is not a validated github.com PR url yields no
#     number at all, so it can never borrow a sole remote's repository and
#     merge an unrelated pull request there.
#   - a raw URL is printed for its REASON, never for its credentials: userinfo
#     is redacted, so a token in a non-GitHub remote does not reach a banner.
#   - FAIL CLOSED: a malformed --repo, an unknown --remote, a sole remote that
#     is not a GitHub repo, a clone with no remotes, and a directory that is not
#     a work tree each get their own refusal verdict. None of them falls through
#     to a target.
#   - PURITY: it never invokes gh, gh-axi, or curl. A resolver that shelled out
#     to the tool to ask "what would you pick?" would inherit the very inference
#     it exists to replace, and would make asking a question indistinguishable
#     from performing a merge.
#
# Mutation (LEDGER_MUTATE=1): the ambiguous case asserts the fail-open - that
# two remotes silently resolve to origin. The rule refuses instead, so it fails.
#
# spec: docs/specs/2026-08-31-merge-target-pin.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-merge-target-lib.sh
. "$ROOT/bin/fm-merge-target-lib.sh"

TMP=$(fm_test_tmproot fm-merge-t1-target)
fm_git_identity

ORIGIN_SLUG=stoneevenson-biz/firstmate
UPSTREAM_SLUG=kunchenguid/firstmate

# --- purity tripwire: gh, gh-axi and curl must never be reached -------------
FAKE=$(fm_fakebin "$TMP")
TRIP="$TMP/tripwire"
for tool in gh gh-axi curl; do
  cat > "$FAKE/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$TRIP"
exit 0
SH
  chmod +x "$FAKE/$tool"
done
PATH="$FAKE:$PATH"; export PATH

verdict() { printf '%s\n' "$1" | head -1 | cut -f1; }
slug()    { printf '%s\n' "$1" | head -1 | cut -f2; }
source_of() { printf '%s\n' "$1" | head -1 | cut -f3; }

# --- fixtures ---------------------------------------------------------------
BOTH="$TMP/both"
fm_git_init_commit "$BOTH"
git -C "$BOTH" remote add origin "git@github.com:$ORIGIN_SLUG.git"
git -C "$BOTH" remote add upstream "https://github.com/$UPSTREAM_SLUG.git"

SOLO="$TMP/solo"
fm_git_init_commit "$SOLO"
git -C "$SOLO" remote add origin "https://github.com/$ORIGIN_SLUG.git"

BARE="$TMP/bare"
fm_git_init_commit "$BARE"

ODD="$TMP/odd"
fm_git_init_commit "$ODD"
git -C "$ODD" remote add mirror "file://$TMP/nowhere"

TRIO="$TMP/trio"
fm_git_init_commit "$TRIO"
git -C "$TRIO" remote add origin "git@github.com:$ORIGIN_SLUG.git"
git -C "$TRIO" remote add upstream "https://github.com/$UPSTREAM_SLUG.git"
git -C "$TRIO" remote add mirror "file://$TMP/nowhere"

# --- 1. precedence ----------------------------------------------------------
out=$(fm_merge_target "$BOTH" "https://github.com/$UPSTREAM_SLUG/pull/5" "picked/by-flag" origin); rc=$?
expect_code 0 "$rc" "an explicit --repo resolves"
[ "$(slug "$out")" = "picked/by-flag" ] || fail "--repo must win over --remote and the url: $out"
[ "$(source_of "$out")" = "--repo" ] || fail "--repo must be reported as the source: $out"

out=$(fm_merge_target "$BOTH" "https://github.com/$UPSTREAM_SLUG/pull/5" "" origin); rc=$?
expect_code 0 "$rc" "--remote resolves"
[ "$(slug "$out")" = "$ORIGIN_SLUG" ] || fail "--remote must win over the PR url: $out"
[ "$(source_of "$out")" = "remote:origin" ] || fail "the source must name the remote: $out"

out=$(fm_merge_target "$BOTH" "https://github.com/$UPSTREAM_SLUG/pull/5" "" ""); rc=$?
expect_code 0 "$rc" "a full PR url resolves on its own"
[ "$(slug "$out")" = "$UPSTREAM_SLUG" ] || fail "a PR url must name its own repo: $out"
[ "$(source_of "$out")" = "pr-url" ] || fail "the source must be pr-url: $out"
pass "precedence: --repo > --remote > PR url > the remote set"

# --- 2. ambiguity is a stop, and names every candidate ----------------------
out=$(fm_merge_target "$BOTH" 5 "" ""); rc=$?
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  expect_code 0 "$rc" "MUTATION: two remotes expected to resolve silently"
  [ "$(slug "$out")" = "$ORIGIN_SLUG" ] || fail "MUTATION: expected a silent preference for origin, got: $out"
else
  expect_code 1 "$rc" "two remotes with no explicit choice must refuse"
  [ "$(verdict "$out")" = AMBIGUOUS ] || fail "the verdict must be AMBIGUOUS: $out"
  assert_contains "$out" "origin"$'\t'"$ORIGIN_SLUG" "the origin candidate is named with its repo"
  assert_contains "$out" "upstream"$'\t'"$UPSTREAM_SLUG" "the upstream candidate is named with its repo"
  [ "$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')" = 2 ] \
    || fail "exactly one row per remote: $out"
  pass "two remotes, no choice: AMBIGUOUS, naming both candidates"

  out=$(fm_merge_target "$TRIO" 5 "" ""); rc=$?
  expect_code 1 "$rc" "three remotes must refuse too"
  assert_contains "$out" "mirror"$'\t'"file://$TMP/nowhere" \
    "a candidate that is not a GitHub repo is shown raw, not omitted"
  [ "$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')" = 3 ] \
    || fail "every remote is a named candidate: $out"
  pass "three remotes: every candidate named, non-GitHub URLs shown as they are"
fi

# --- 3. a sole remote is not a choice between candidates --------------------
out=$(fm_merge_target "$SOLO" 5 "" ""); rc=$?
expect_code 0 "$rc" "a single-remote clone resolves"
[ "$(slug "$out")" = "$ORIGIN_SLUG" ] || fail "the sole remote is the target: $out"
[ "$(source_of "$out")" = "sole-remote:origin" ] || fail "the source names the sole remote: $out"
pass "a sole remote resolves, and says it was the only candidate"

# --- 4. every URL form git stores, and nothing else -------------------------
for url in \
  "git@github.com:$ORIGIN_SLUG.git" \
  "git@github.com:$ORIGIN_SLUG" \
  "https://github.com/$ORIGIN_SLUG.git" \
  "https://github.com/$ORIGIN_SLUG" \
  "https://github.com/$ORIGIN_SLUG/" \
  "https://x-access-token:tok@github.com/$ORIGIN_SLUG.git" \
  "ssh://git@github.com/$ORIGIN_SLUG.git" \
  "git://github.com/$ORIGIN_SLUG.git" \
  "http://github.com/$ORIGIN_SLUG.git"
do
  got=$(fm_merge_target_from_url "$url") || fail "must parse a GitHub remote: $url"
  [ "$got" = "$ORIGIN_SLUG" ] || fail "parsed '$got' from '$url', expected $ORIGIN_SLUG"
done
for url in \
  "file:///tmp/whatever" \
  "git@gitlab.com:$ORIGIN_SLUG.git" \
  "https://github.example.com/$ORIGIN_SLUG.git" \
  "https://github.com/owner" \
  "https://github.com/owner/repo/extra" \
  "https://evil.example.com/x@github.com/$ORIGIN_SLUG" \
  "ssh://git@github.com:22/$ORIGIN_SLUG.git" \
  ""
do
  ! fm_merge_target_from_url "$url" >/dev/null 2>&1 \
    || fail "must NOT parse as a GitHub repo: '$url'"
done
got=$(fm_merge_target_from_url "https://tok@github.com/$ORIGIN_SLUG.git") \
  || fail "credentials in the authority are stripped, not treated as a host"
[ "$got" = "$ORIGIN_SLUG" ] || fail "credential form parsed '$got'"
pass "URL parsing: every form git stores, and a firm no for everything else - including a host whose PATH merely contains '@github.com/'"

# --- 5. PR references -------------------------------------------------------
[ "$(fm_merge_target_pr_number 5)" = 5 ] || fail "a bare number is a PR number"
[ "$(fm_merge_target_pr_number "https://github.com/$ORIGIN_SLUG/pull/12")" = 12 ] || fail "url -> number"
[ "$(fm_merge_target_pr_number "https://github.com/$ORIGIN_SLUG/pull/12/files")" = 12 ] || fail "url with path -> number"
[ "$(fm_merge_target_pr_number "https://github.com/$ORIGIN_SLUG/pull/12#issuecomment-1")" = 12 ] || fail "url with anchor -> number"
! fm_merge_target_pr_number "" >/dev/null 2>&1 || fail "empty is not a PR reference"
! fm_merge_target_pr_number "not-a-pr" >/dev/null 2>&1 || fail "a bare word is not a PR reference"
! fm_merge_target_from_pr_url "https://gitlab.com/o/r/pull/5" >/dev/null 2>&1 \
  || fail "only github.com PR urls name a GitHub repo"

# THE NUMBER AND THE REPOSITORY MUST COME FROM THE SAME VALIDATED PARSE.
# Accepting any `*/pull/<digits>` here was a fail-open the whole path inherited:
# fm_merge_target_from_pr_url refuses a foreign ref as a REPOSITORY, so
# resolution fell through to the clone's sole remote - and a caller naming a
# pull request on another system got that NUMBER merged in the captain's own
# repository instead. The repo was right; the pull request was one nobody named.
for foreign in \
  "https://gitlab.com/other/proj/pull/23" \
  "ticket/pull/9" \
  "../../etc/pull/7" \
  "https://github.com/o/r/issues/5" \
  "https://github.com/o/r/pull/abc" \
  "https://github.example.com/o/r/pull/4" \
  "not-a-pr"
do
  ! fm_merge_target_pr_number "$foreign" >/dev/null 2>&1 \
    || fail "must not read a PR number out of '$foreign' (got $(fm_merge_target_pr_number "$foreign"))"
done
pass "PR references: numbers and validated github.com urls only - a foreign /pull/<n> yields NO number"

# --- 5b. a foreign ref never reaches a merge, even where the repo resolves ---
FOREIGN_OUT=$("$ROOT/bin/fm-merge-pr.sh" t1x "https://gitlab.com/other/proj/pull/23" \
  --project "$SOLO" --dry-run 2>&1); FRC=$?
expect_code 1 "$FRC" "a foreign PR ref must refuse even in an unambiguous clone"
assert_contains "$FOREIGN_OUT" "REFUSED" "the refusal is loud"
assert_not_contains "$FOREIGN_OUT" "gh-axi pr merge" "no merge command may be produced for a foreign ref"
pass "a foreign /pull/<n> ref refuses outright - it never borrows the sole remote's repository"

# --- 6. every refusal has its own verdict, and none falls through -----------
for bad in "not a slug" "owner" "a/b/c" "own er/name" "/name" "owner/" \
           "../etc" "./x" "owner/.." "owner/." "-flag/name" "owner/-flag"; do
  out=$(fm_merge_target "$SOLO" 5 "$bad" ""); rc=$?
  expect_code 1 "$rc" "a malformed --repo must refuse: '$bad'"
  [ "$(verdict "$out")" = BADREPO ] || fail "expected BADREPO for '$bad', got: $out"
done

out=$(fm_merge_target "$SOLO" 5 "" nosuchremote); rc=$?
expect_code 1 "$rc" "an unknown remote must refuse"
[ "$(verdict "$out")" = BADREMOTE ] || fail "expected BADREMOTE: $out"
assert_contains "$out" "no such remote" "the refusal says the remote does not exist"

out=$(fm_merge_target "$ODD" 5 "" ""); rc=$?
expect_code 1 "$rc" "a sole remote that is not a GitHub repo must refuse"
[ "$(verdict "$out")" = BADREMOTE ] || fail "expected BADREMOTE for a non-GitHub sole remote: $out"

out=$(fm_merge_target "$BARE" 5 "" ""); rc=$?
expect_code 1 "$rc" "a clone with no remotes must refuse"
[ "$(verdict "$out")" = NOREMOTE ] || fail "expected NOREMOTE: $out"

mkdir -p "$TMP/plain"
out=$(fm_merge_target "$TMP/plain" 5 "" ""); rc=$?
expect_code 2 "$rc" "a non-work-tree cannot be inspected"
[ "$(verdict "$out")" = NOTAGIT ] || fail "expected NOTAGIT: $out"
pass "fail closed: BADREPO, BADREMOTE, NOREMOTE and NOTAGIT each refuse on their own terms"

# --- 6b. a raw URL is shown for its reason, never for its credentials -------
CRED="$TMP/cred"
fm_git_init_commit "$CRED"
git -C "$CRED" remote add mirror "https://someone:s3cr3t-token@gitlab.example/o/r.git"
out=$(fm_merge_target "$CRED" 5 "" ""); rc=$?
expect_code 1 "$rc" "a sole non-GitHub remote refuses"
assert_contains "$out" "gitlab.example/o/r.git" "the reason survives: the reader sees which URL was no help"
assert_not_contains "$out" "s3cr3t-token" "the credential must never be printed"

git -C "$CRED" remote add other "file://$TMP/nowhere"
out=$(fm_merge_target "$CRED" 5 "" ""); rc=$?
expect_code 1 "$rc" "two remotes refuse"
assert_not_contains "$out" "s3cr3t-token" "an AMBIGUOUS row must not print a credential either"

[ "$(fm_merge_target_redact_url "https://u:p@host/x")" = "https://***@host/x" ] || fail "userinfo is redacted"
[ "$(fm_merge_target_redact_url "https://github.com/o/r@x")" = "https://github.com/o/r@x" ] \
  || fail "an @ in the PATH is not userinfo and must not be mangled"
pass "raw URLs are shown for their reason with any credential redacted"

# --- 7. the remote-naming helper informs, it never decides ------------------
[ "$(fm_merge_target_remote_for "$BOTH" "$UPSTREAM_SLUG")" = upstream ] || fail "must name the upstream remote"
[ "$(fm_merge_target_remote_for "$BOTH" "$ORIGIN_SLUG")" = origin ] || fail "must name the origin remote"
! fm_merge_target_remote_for "$BOTH" "stranger/repo" >/dev/null 2>&1 \
  || fail "an unrelated repo belongs to no remote"
pass "the remote-naming helper answers for messages only"

# --- 8. purity --------------------------------------------------------------
[ ! -e "$TRIP" ] || fail "the resolver must never invoke gh, gh-axi or curl: $(cat "$TRIP")"
pass "purity: the whole rule ran without invoking gh, gh-axi or curl once"
