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
#   - ONE PARSE OF ONE URL. The url is taken apart in the order a url is
#     defined - fragment, query, scheme, host, path - and both the repository
#     and the number come out of that single parse, so they cannot disagree.
#     The accepted shape is exactly `http(s)://github.com/<owner>/<repo>/pull/
#     <digits>`; a foreign host, a second `/pull/<n>` in the query or the
#     fragment, and anything trailing in the path are each REFUSED, and each is
#     gated as its own case so no one tweak can silently re-open a single one.
#   - THE NUMBER AND THE REPOSITORY COME FROM ONE PARSE, AND THEY MUST AGREE.
#     A ref containing `/pull/<digits>` that is not a validated github.com PR
#     url yields no number at all, so it can never borrow a sole remote's
#     repository and merge an unrelated pull request there; and a url that IS
#     valid but names a repository other than the resolved target is a
#     CONFLICT, because once --repo or --remote wins precedence only the NUMBER
#     survives the url. PR 23 in `other/proj` is not PR 23 in the captain's own
#     repository, and nothing in the input says which was meant. The NUMBER is
#     read at the same `/pull/` the slug was parsed from - the first - so a url
#     carrying a second `/pull/<n>` in its query, anchor or trailing path
#     cannot substitute that number for the one the url names.
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

# --- 5. PR references: ONE parse, and every rejection gated on its own -------
#
# Three wrong-merge defects came out of this parser, all the same shape: a value
# read from a reference that did not name it. Each was patched where it was
# found and the next arrived through the next door - a foreign host lending its
# number, a url outvoted on repository but not on number, then the slug read at
# the first `/pull/` and the number at the last. So the matching is gone and the
# url is taken apart in the order a url is defined: fragment, query, scheme,
# host, path. Both answers come from that ONE parse, which is why they can no
# longer disagree.
#
# EVERY REJECTION BELOW IS ITS OWN CASE with its own `pass`, deliberately, so
# that no single tweak to the parser can silently re-open one of them: a change
# that reopens the anchor hole fails the anchor case by name, and says so.

# 5.1 what is accepted: exactly the canonical form, with an innocent query or
#     fragment allowed because neither can reach the path parser.
[ "$(fm_merge_target_pr_number 5)" = 5 ] || fail "a bare number is a PR number"
for good in \
  "https://github.com/$ORIGIN_SLUG/pull/12" \
  "http://github.com/$ORIGIN_SLUG/pull/12" \
  "https://github.com/$ORIGIN_SLUG/pull/12?w=1" \
  "https://github.com/$ORIGIN_SLUG/pull/12#issuecomment-1" \
  "https://github.com/$ORIGIN_SLUG/pull/12?w=1#top"
do
  [ "$(fm_merge_target_pr_number "$good")" = 12 ] || fail "must read 12 from '$good'"
  [ "$(fm_merge_target_from_pr_url "$good")" = "$ORIGIN_SLUG" ] || fail "must read the slug from '$good'"
  [ "$(fm_merge_target_parse_pr_url "$good")" = "$ORIGIN_SLUG"$'\t'"12" ] \
    || fail "one parse must yield both values for '$good'"
done
pass "5.1 accepted: the canonical url, http or https, with an innocent query or fragment"

# 5.2 FOREIGN HOST. The ref the Quarterdeck reproduced. It must yield neither a
#     repository nor a number - a number alone would be lent to whichever
#     repository the remotes resolved.
for host in \
  "https://gitlab.com/other/proj/pull/23" \
  "https://github.example.com/$ORIGIN_SLUG/pull/12" \
  "https://evil.example.com/x@github.com/$ORIGIN_SLUG/pull/12" \
  "https://notgithub.com/$ORIGIN_SLUG/pull/12" \
  "ticket/pull/9" \
  "../../etc/pull/7"
do
  ! fm_merge_target_from_pr_url "$host" >/dev/null 2>&1 || fail "foreign host must name no repository: $host"
  ! fm_merge_target_pr_number "$host" >/dev/null 2>&1 || fail "foreign host must yield no number: $host"
done
pass "5.2 rejected: a foreign host yields neither a repository nor a number"

# 5.3 A SECOND /pull/<n> IN THE QUERY. A reference names exactly one pull
#     request; one that mentions a second is ambiguous about its own subject.
for q in \
  "https://github.com/$ORIGIN_SLUG/pull/12?next=/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12?to=https://github.com/other/proj/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12?a=1&b=/pull/99"
do
  ! fm_merge_target_pr_number "$q" >/dev/null 2>&1 \
    || fail "a second /pull/ in the QUERY must refuse, got $(fm_merge_target_pr_number "$q"): $q"
  ! fm_merge_target_from_pr_url "$q" >/dev/null 2>&1 || fail "and must name no repository: $q"
done
pass "5.3 rejected: a second /pull/<n> in the query string"

# 5.4 A SECOND /pull/<n> IN THE ANCHOR. Same rule, the other delimiter - gated
#     apart from 5.3 because they are parsed at different steps.
for a in \
  "https://github.com/$ORIGIN_SLUG/pull/12#x/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12#/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12?w=1#see/pull/99"
do
  ! fm_merge_target_pr_number "$a" >/dev/null 2>&1 \
    || fail "a second /pull/ in the ANCHOR must refuse, got $(fm_merge_target_pr_number "$a"): $a"
  ! fm_merge_target_from_pr_url "$a" >/dev/null 2>&1 || fail "and must name no repository: $a"
done
pass "5.4 rejected: a second /pull/<n> in the fragment"

# 5.5 TRAILING PATH SEGMENTS. Refused rather than trimmed: trimming is how a url
#     that says one thing came to mean another, and `/pull/12/files/pull/77` is
#     the same trick wearing a path.
for t in \
  "https://github.com/$ORIGIN_SLUG/pull/12/files" \
  "https://github.com/$ORIGIN_SLUG/pull/12/commits/abc" \
  "https://github.com/$ORIGIN_SLUG/pull/12/files/pull/77" \
  "https://github.com/$ORIGIN_SLUG/pull/12/"
do
  ! fm_merge_target_pr_number "$t" >/dev/null 2>&1 \
    || fail "a trailing path segment must refuse, got $(fm_merge_target_pr_number "$t"): $t"
done
pass "5.5 rejected: anything trailing the pull request in the path"

# 5.6 MALFORMED PATHS. Not a pull url at all, or no number where one belongs.
for m in \
  "https://github.com/$ORIGIN_SLUG/issues/5" \
  "https://github.com/$ORIGIN_SLUG/pull/abc" \
  "https://github.com/$ORIGIN_SLUG/pull/" \
  "https://github.com/$ORIGIN_SLUG/pull" \
  "https://github.com/$ORIGIN_SLUG" \
  "https://github.com/owner/pull/12" \
  "not-a-pr" \
  ""
do
  ! fm_merge_target_pr_number "$m" >/dev/null 2>&1 || fail "malformed ref must refuse: '$m'"
done
pass "5.6 rejected: a path that is not exactly <owner>/<repo>/pull/<digits>"

# 5.7 END TO END: none of the above can produce a merge command, and the
#     canonical form still merges the pull request it names.
for bad_e2e in \
  "https://gitlab.com/other/proj/pull/23" \
  "https://github.com/$ORIGIN_SLUG/pull/12?next=/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12#x/pull/99" \
  "https://github.com/$ORIGIN_SLUG/pull/12/files"
do
  E2E=$("$ROOT/bin/fm-merge-pr.sh" t1w "$bad_e2e" --project "$SOLO" --dry-run 2>&1); ERC=$?
  expect_code 1 "$ERC" "must refuse through the merge path: $bad_e2e"
  assert_not_contains "$E2E" "gh-axi pr merge" "no merge command may be produced for: $bad_e2e"
done
GOOD_E2E=$("$ROOT/bin/fm-merge-pr.sh" t1w "https://github.com/$ORIGIN_SLUG/pull/12" \
  --project "$SOLO" --dry-run 2>/dev/null) || fail "the canonical url must merge"
assert_contains "$GOOD_E2E" "gh-axi pr merge 12 --repo $ORIGIN_SLUG" "the canonical url merges the PR it names"
assert_not_contains "$GOOD_E2E" "merge 99" "no second number may ever surface"
pass "5.7 end to end: every rejected shape emits no merge command; the canonical one merges 12"

! fm_merge_target_pr_number "" >/dev/null 2>&1 || fail "empty is not a PR reference"
! fm_merge_target_pr_number "not-a-pr" >/dev/null 2>&1 || fail "a bare word is not a PR reference"
! fm_merge_target_from_pr_url "https://gitlab.com/o/r/pull/5" >/dev/null 2>&1 \
  || fail "only github.com PR urls name a GitHub repo"


# --- 5c. a url and a target that disagree are two answers, not one ----------
#
# Restricting the number to a VALIDATED github.com url closes the foreign-host
# half. This is the rest: a well-formed url for `other/proj` plus an explicitly
# named target passed both checks on their own terms, and then only the NUMBER
# survived the url - merging PR 23 of the target repository instead.
CONF=$(fm_merge_target_pr_slug_conflict "$ORIGIN_SLUG" "https://github.com/other/proj/pull/23") \
  || fail "a url naming another repository must be reported as a conflict"
[ "$CONF" = "other/proj" ] || fail "the conflict must name the repository the url claims: $CONF"

! fm_merge_target_pr_slug_conflict "$ORIGIN_SLUG" "https://github.com/$ORIGIN_SLUG/pull/9" >/dev/null 2>&1 \
  || fail "a url naming the target agrees with it and is no conflict"
! fm_merge_target_pr_slug_conflict "$ORIGIN_SLUG" 9 >/dev/null 2>&1 \
  || fail "a bare number claims no repository and can conflict with none"
! fm_merge_target_pr_slug_conflict "$ORIGIN_SLUG" "https://gitlab.com/o/r/pull/9" >/dev/null 2>&1 \
  || fail "a ref that names no GitHub repository makes no claim to conflict with"
pass "a PR url that names a different repository than the target is a conflict, and only that"

for bad_pair in "--remote:origin" "--repo:$ORIGIN_SLUG"; do
  flag=${bad_pair%%:*}; val=${bad_pair#*:}
  CONF_OUT=$("$ROOT/bin/fm-merge-pr.sh" t1y "https://github.com/other/proj/pull/23" \
    --project "$SOLO" "$flag" "$val" --dry-run 2>&1); CRC=$?
  expect_code 1 "$CRC" "a url/target conflict must refuse ($flag)"
  assert_contains "$CONF_OUT" "CONFLICTS WITH THE MERGE TARGET" "the refusal names the conflict ($flag)"
  assert_contains "$CONF_OUT" "other/proj" "the refusal names the url's repository ($flag)"
  assert_contains "$CONF_OUT" "$ORIGIN_SLUG" "the refusal names the resolved target ($flag)"
  assert_not_contains "$CONF_OUT" "gh-axi pr merge" "no merge command may be produced on a conflict ($flag)"
done

AGREE=$("$ROOT/bin/fm-merge-pr.sh" t1z "https://github.com/$ORIGIN_SLUG/pull/9" \
  --project "$SOLO" --remote origin --dry-run 2>/dev/null); ARC=$?
expect_code 0 "$ARC" "a url that agrees with the target still merges"
assert_contains "$AGREE" "gh-axi pr merge 9 --repo $ORIGIN_SLUG" "the agreeing case is unchanged"
pass "url/target conflict refuses through the merge path; agreement still merges"

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
