#!/usr/bin/env bash
# T2: ONE GATE PER WAY THE MERGE TARGET CAN BE INFLUENCED.
#
# WHY THIS SUITE IS SHAPED BY VECTOR AND NOT BY FEATURE. The wrong-repo guard
# took three rounds to write, and all three rejections were the same class of
# defect wearing a different coat: a value read from something that did not name
# it. Each round asked "is this reference valid?", patched the one input that had
# proved it was not, and shipped - and the next round arrived through a door the
# patch had never been pointed at. A url on a foreign host. A second /pull/ in a
# query. A second /pull/ in a fragment. Then `-Rowner/repo` after `--`, which was
# not a url at all.
#
# So the question this suite asks is not whether an input is valid. It is:
#
#     can ANY input, in ANY position, cause a merge against a repository other
#     than the one resolved from this clone's origin?
#
# and it asks it once per DOOR, with a gate of its own behind each. That is
# deliberate and it is the whole design: a single "rejects bad input" gate would
# have gone green after round one and stayed green through rounds two and three,
# because each patch really did fix the input it was shown. Ten narrow gates
# cannot do that. No single regex, and no refactor of one, can reopen a vector
# without a gate that names that vector going red.
#
# Every case therefore asserts a NAMED rail - `REFUSED[<rail>]` - not merely a
# non-zero exit. A refusal that only proves SOMETHING stopped is exactly what let
# three different holes look alike from the outside.
#
# Vectors gated here, one case each:
#   foreign-host            a pull-request url on another host
#   pull-in-query           a second /pull/<n> in the query string
#   pull-in-fragment        a second /pull/<n> in the fragment
#   trailing-path           path segments after the pull-request number
#   passthrough-repo-flag   -R / --repo after `--`, in EVERY spelling: detached,
#                           inline, attached (-Rowner/repo), clustered (-dRx),
#                           and one posing as a sanctioned option's VALUE
#   duplicate-repo-flag     the same target flag twice, or --repo and --remote
#                           naming different repositories
#   ambiguous-remotes       a bare number in a clone with more than one remote
#   env-redirect            GH_REPO / GH_HOST redirecting a gh-shaped tool, and
#                           GIT_DIR redirecting `git -C` itself, without ever
#                           appearing in an argument
#   git-config-substitution the GIT_CONFIG family (and the global config files
#                           HOME/XDG_CONFIG_HOME choose) substituting the remote
#                           URL itself via url.<other>.insteadOf, so the
#                           resolution and the origin proof read the same
#                           substituted value and agree
#   origin-proof            a target that is not this clone's origin, or an
#                           origin that cannot be read at all
#   argv-egress             the finished argv, re-read, must pin the target once
#
# Four of these (the first four) were already closed when this suite was written.
# They are gated anyway: an untested closure is an assumption, and the assumption
# these gates replace is the one that cost three rounds.
#
# NO REAL MERGE IS EVER RUN. The boundary is stubbed - a fake `gh-axi` first on
# PATH that records its argv and its environment and exits. Nothing here reaches
# the network, and the fixtures' "remotes" are URLs that are never fetched. The
# stub models gh's two real target-resolution behaviours on purpose: absent an
# explicit repository it falls back to GH_REPO and then to the inferred parent,
# and when given several repo flags it keeps the LAST. Both are the defect, so
# every "landed in origin" assertion below is a claim about the code under test.
#
# Usage: bash tests/fm-merge-t2-vectors.test.sh [<case>...]   (default: all)
#
# Mutation (LEDGER_MUTATE=1): each case asserts the UNSAFE outcome instead - that
# the vector reaches a merge. A correct merge path refuses, so the case fails.
#
# spec: docs/specs/2026-08-31-merge-target-pin.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MUTATE="${LEDGER_MUTATE:-0}"

TMP=$(fm_test_tmproot fm-merge-t2-vectors)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
fm_git_identity

ORIGIN_SLUG=stoneevenson-biz/firstmate
UPSTREAM_SLUG=kunchenguid/firstmate
EVIL_SLUG=attacker/loot

# BOTH: the ~/firstmate shape - a fork plus its parent.
BOTH="$TMP/both"
fm_git_init_commit "$BOTH"
git -C "$BOTH" remote add origin "git@github.com:$ORIGIN_SLUG.git"
git -C "$BOTH" remote add upstream "https://github.com/$UPSTREAM_SLUG.git"

# SOLO: one remote, named origin. The unambiguous, everyday case.
SOLO="$TMP/solo"
fm_git_init_commit "$SOLO"
git -C "$SOLO" remote add origin "git@github.com:$ORIGIN_SLUG.git"

# NOORIGIN: one remote, NOT named origin. Resolvable, but unprovable.
NOORIGIN="$TMP/noorigin"
fm_git_init_commit "$NOORIGIN"
git -C "$NOORIGIN" remote add fork "git@github.com:$UPSTREAM_SLUG.git"

# ELSEWHERE: a clone the caller never names. `GIT_DIR` pointing here is enough
# to make every `git -C <the real clone>` read THIS repository's remotes instead.
ELSEWHERE="$TMP/elsewhere"
fm_git_init_commit "$ELSEWHERE"
git -C "$ELSEWHERE" remote add origin "git@github.com:$EVIL_SLUG.git"

FAKE=$(fm_fakebin "$TMP")
cat > "$FAKE/gh-axi" <<'SH'
#!/usr/bin/env bash
# Models the two ways gh decides which repository a PR operation lands in:
#   1. the LAST repo flag in the argv wins, in any spelling;
#   2. with no repo flag, GH_REPO, then the inferred parent of a fork.
# Both are pointed at the WRONG repository on purpose - they are the defect.
repo=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[i]}" in
    --repo|-R) repo="${args[$((i + 1))]:-}" ;;
    --repo=*)  repo="${args[i]#--repo=}" ;;
    -R=*)      repo="${args[i]#-R=}" ;;
    -R?*)      repo="${args[i]#-R}" ;;
    -[!-]*R?*) repo="${args[i]#*R}" ;;
  esac
  i=$((i + 1))
done
[ -n "$repo" ] || repo="${GH_REPO:-${FM_TEST_GH_INFERRED:-INFERRED-NOTHING}}"
{
  printf 'argv=%s\n' "$*"
  printf 'merged-into=%s\n' "$repo"
  printf 'env-repo=%s\n' "${GH_REPO:-<unset>}"
  printf 'env-host=%s\n' "${GH_HOST:-<unset>}"
} >> "$FM_TEST_GH_RECORD"
SH
chmod +x "$FAKE/gh-axi"
PATH="$FAKE:$PATH"; export PATH
export FM_TEST_GH_INFERRED="$UPSTREAM_SLUG"

REC="$TMP/gh.log"
export FM_TEST_GH_RECORD="$REC"
reset_record() { : > "$REC"; }
record() { cat "$REC"; }
assert_no_merge() { [ ! -s "$REC" ] || fail "$1: the merge tool must never be invoked, but was: $(record)"; }

MERGE="$ROOT/bin/fm-merge-pr.sh"
# shellcheck source=bin/fm-merge-target-lib.sh
. "$ROOT/bin/fm-merge-target-lib.sh"

# refuses_with <rail> <label> -- <merge args>...
# The one assertion shape every vector case uses: the command refuses, names its
# own rail, and reaches no merge tool. Under LEDGER_MUTATE it asserts the reverse.
refuses_with() {
  local rail=$1 label=$2; shift 3
  local out code one
  reset_record
  out=$("$MERGE" "$@" 2>&1); code=$?
  if [ "$MUTATE" = 1 ]; then
    expect_code 0 "$code" "MUTATION: $label expected to merge anyway"
    assert_contains "$(record)" "merged-into=" "MUTATION: $label expected to reach the merge tool"
    return 0
  fi
  expect_code 1 "$code" "$label must refuse: $out"
  assert_contains "$out" "REFUSED[$rail]" "$label must name its own rail, not refuse generically: $out"
  assert_no_merge "$label"
}

# ============================================================================
case_foreign_host() {
  # A url on another host is a pull request in another system. Round one matched
  # any `*/pull/<digits>` string, so this url's 23 was lent to whichever
  # repository the remotes happened to resolve.
  refuses_with pr-ref/foreign-host "a gitlab.com pull url" -- \
    t2fh "https://gitlab.com/other/proj/pull/23" --project "$SOLO"
  [ "$MUTATE" = 1 ] && return 0

  # The same rail, asked of the parser directly: scheme and host are matched
  # exactly, so a github.com that is only in the PATH is still foreign.
  assert_contains "$(fm_merge_target_pr_ref_reason "https://gitlab.com/o/r/pull/23")" \
    "foreign-host" "gitlab.com is a foreign host"
  assert_contains "$(fm_merge_target_pr_ref_reason "https://evil.example.com/x@github.com/o/r/pull/23")" \
    "foreign-host" "a github.com appearing in the PATH is not the host"
  assert_contains "$(fm_merge_target_pr_ref_reason "ssh://github.com/o/r/pull/23")" \
    "foreign-host" "a scheme that is not http(s) is not how a pull request is addressed"
  pass "foreign-host: a pull-request url off github.com refuses on its own named rail"
}

# ============================================================================
case_pull_in_query() {
  # Round three: the slug was read at the FIRST /pull/ and the number at the
  # LAST, so this url merged PR 99 while every cross-check saw a repository
  # agreeing with itself.
  refuses_with pr-ref/second-pull-in-query "a url with a second /pull/ in its query" -- \
    t2pq "https://github.com/$ORIGIN_SLUG/pull/12?next=/pull/99" --project "$SOLO"
  [ "$MUTATE" = 1 ] && return 0

  assert_contains "$(fm_merge_target_pr_ref_reason "https://github.com/o/r/pull/12?x=/pull/99")" \
    "second-pull-in-query" "a query naming a second pull request is ambiguous"
  # An innocent query is not a second pull request and must still merge.
  reset_record
  out=$("$MERGE" t2pq2 "https://github.com/$ORIGIN_SLUG/pull/12?w=1" --project "$SOLO" 2>&1); code=$?
  expect_code 0 "$code" "an innocent query must not be collateral damage: $out"
  assert_contains "$(record)" "argv=pr merge 12 " "the number comes from the one /pull/ the url has"
  pass "pull-in-query: a second /pull/ in the query refuses; an innocent query still merges"
}

# ============================================================================
case_pull_in_fragment() {
  refuses_with pr-ref/second-pull-in-fragment "a url with a second /pull/ in its fragment" -- \
    t2pf "https://github.com/$ORIGIN_SLUG/pull/12#/pull/99" --project "$SOLO"
  [ "$MUTATE" = 1 ] && return 0

  assert_contains "$(fm_merge_target_pr_ref_reason "https://github.com/o/r/pull/12#/pull/99")" \
    "second-pull-in-fragment" "a fragment naming a second pull request is ambiguous"
  # The fragment is stripped BEFORE the query, so a /pull/ that is only in the
  # fragment is never mis-attributed to the query rail, and vice versa.
  assert_contains "$(fm_merge_target_pr_ref_reason "https://github.com/o/r/pull/12#discussion_r1?a=/pull/9")" \
    "second-pull-in-fragment" "a query-looking string inside a fragment is fragment, not query"
  reset_record
  out=$("$MERGE" t2pf2 "https://github.com/$ORIGIN_SLUG/pull/12#issuecomment-1" --project "$SOLO" 2>&1); code=$?
  expect_code 0 "$code" "an innocent fragment must not be collateral damage: $out"
  assert_contains "$(record)" "argv=pr merge 12 " "the number comes from the one /pull/ the url has"
  pass "pull-in-fragment: a second /pull/ in the fragment refuses; an innocent fragment still merges"
}

# ============================================================================
case_trailing_path() {
  # `/files` is refused, never trimmed. Trimming is how a url that says one
  # thing came to mean another.
  refuses_with pr-ref/trailing-path "a url with /files after the number" -- \
    t2tp "https://github.com/$ORIGIN_SLUG/pull/12/files" --project "$SOLO"
  [ "$MUTATE" = 1 ] && return 0

  for trailing in \
    "https://github.com/o/r/pull/12/files" \
    "https://github.com/o/r/pull/12/commits/abc" \
    "https://github.com/o/r/pull/12/../../other/repo/pull/99"; do
    assert_contains "$(fm_merge_target_pr_ref_reason "$trailing")" "trailing-path" \
      "nothing may trail the pull-request number: $trailing"
  done
  pass "trailing-path: anything after the number refuses rather than being trimmed away"
}

# ============================================================================
case_passthrough_repo_flag() {
  # THE CONTROL, and the red this gate freezes: the tool really does keep the
  # LAST repo flag, so one spelling that slips through the guard is a merge into
  # a repository nobody named. Round three's guard knew four spellings; the
  # attached form `-Rowner/repo` was a fifth.
  if [ "$MUTATE" != 1 ]; then
    reset_record
    gh-axi pr merge 5 --repo "$ORIGIN_SLUG" -R"$EVIL_SLUG"
    assert_contains "$(record)" "merged-into=$EVIL_SLUG" \
      "control: an attached -R after a pin really does win - this is the red"
  fi

  for smuggle in \
    "--repo $EVIL_SLUG" "--repo=$EVIL_SLUG" \
    "-R $EVIL_SLUG" "-R=$EVIL_SLUG" \
    "-R$EVIL_SLUG" "-dR $EVIL_SLUG" "-dR$EVIL_SLUG" "--squash -R$EVIL_SLUG"; do
    # shellcheck disable=SC2086  # deliberate word-splitting: each case is an argv
    refuses_with passthrough/repo-flag "a repo flag after -- ($smuggle)" -- \
      t2pt 5 --project "$SOLO" -- $smuggle
  done
  [ "$MUTATE" = 1 ] && return 0

  # The allowlist's own edges: a short flag that names no repository is refused
  # too, because short flags cluster and carry attached values - the property
  # that made the blocklist unwinnable. An unknown long option is refused, not
  # forwarded. A bare argument is refused. And sanctioned options still work.
  refuses_with passthrough/short-flag "a harmless short flag" -- \
    t2pt2 5 --project "$SOLO" -- -d
  refuses_with passthrough/unknown-flag "an option not on the allowlist" -- \
    t2pt3 5 --project "$SOLO" -- --repo-owner
  refuses_with passthrough/positional "a bare argument after --" -- \
    t2pt4 5 --project "$SOLO" -- "$EVIL_SLUG"

  # THE ARITY MODEL MUST NOT BE LOAD-BEARING. "--body takes one word" is this
  # code's BELIEF about gh, not something it can check - and if the belief were
  # ever wrong, an argument sitting where a value was expected would be a flag to
  # gh while being skipped here. So a value that could itself name a repository
  # refuses too, in both the detached and the inline form.
  refuses_with passthrough/repo-flag-as-value "a repo flag sitting where a value is expected" -- \
    t2pt6 5 --project "$SOLO" -- --body "-R$EVIL_SLUG"
  refuses_with passthrough/repo-flag-as-value "a repo flag inline as a value" -- \
    t2pt7 5 --project "$SOLO" -- "--body=-R$EVIL_SLUG"

  reset_record
  out=$("$MERGE" t2pt5 5 --project "$SOLO" -- --squash --delete-branch --body "merges the -R work" 2>&1); code=$?
  expect_code 0 "$code" "sanctioned passthrough options must still reach the tool: $out"
  assert_contains "$(record)" "--repo $ORIGIN_SLUG" "the pin survives passthrough"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "an ordinary body is data and changes nothing"
  assert_contains "$(record)" "--squash --delete-branch" "sanctioned options reach the tool"
  pass "passthrough-repo-flag: every -R spelling refuses, including one posing as an option value"
}

# ============================================================================
case_duplicate_repo_flag() {
  # Two statements about one merge. "The last one wins" is precisely the gh
  # behaviour this whole path exists to stop depending on, so repetition stops
  # rather than being resolved by precedence.
  refuses_with target/duplicate-flag "--repo given twice" -- \
    t2df 5 --project "$SOLO" --repo "$ORIGIN_SLUG" --repo "$EVIL_SLUG"
  refuses_with target/duplicate-flag "--repo given twice with the SAME value" -- \
    t2df2 5 --project "$SOLO" --repo "$ORIGIN_SLUG" --repo "$ORIGIN_SLUG"
  refuses_with target/duplicate-flag "--remote given twice" -- \
    t2df3 5 --project "$BOTH" --remote origin --remote upstream
  refuses_with target/duplicate-flag "--project given twice" -- \
    t2df4 5 --project "$SOLO" --project "$BOTH"
  refuses_with target/conflicting-flags "--repo and --remote naming different repositories" -- \
    t2df5 5 --project "$BOTH" --repo "$EVIL_SLUG" --remote origin
  [ "$MUTATE" = 1 ] && return 0

  # Agreeing is not conflicting: --repo and --remote that name the same
  # repository are one statement said twice, and must not be collateral damage.
  reset_record
  out=$("$MERGE" t2df6 5 --project "$BOTH" --repo "$ORIGIN_SLUG" --remote origin 2>&1); code=$?
  expect_code 0 "$code" "--repo and --remote that agree must merge: $out"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the agreed target is used"
  pass "duplicate-repo-flag: a target is named once; a disagreement stops, an agreement does not"
}

# ============================================================================
case_ambiguous_remotes() {
  # A bare number exists independently in every remote. Nothing in the input
  # says which, and deciding that is not mechanical.
  refuses_with target/ambiguous-remotes "a bare number in a two-remote clone" -- \
    t2am 5 --project "$BOTH"
  [ "$MUTATE" = 1 ] && return 0

  reset_record
  out=$("$MERGE" t2am2 5 --project "$BOTH" 2>&1) || true
  assert_contains "$out" "$ORIGIN_SLUG" "the refusal names origin's repository"
  assert_contains "$out" "$UPSTREAM_SLUG" "the refusal names upstream's repository"
  assert_contains "$out" "--remote" "the refusal says how to disambiguate"
  assert_not_contains "$out" "merge target: " "no target may be announced by a merge that refused"
  pass "ambiguous-remotes: refuses, names every candidate, and never quietly prefers origin"
}

# ============================================================================
case_env_redirect() {
  # GH_REPO and GH_HOST redirect a gh-shaped tool without appearing in the argv
  # the egress check reads - and the same owner/name on another host is another
  # repository. So the environment is PINNED at the exec, not inherited.
  if [ "$MUTATE" != 1 ]; then
    reset_record
    GH_REPO="$EVIL_SLUG" gh-axi pr merge 5
    assert_contains "$(record)" "merged-into=$EVIL_SLUG" \
      "control: GH_REPO alone really does decide the target - this is the red"
  fi

  reset_record
  out=$(GH_REPO="$EVIL_SLUG" GH_HOST="evil.example.com" \
        "$MERGE" t2env 5 --project "$SOLO" 2>&1); code=$?
  if [ "$MUTATE" = 1 ]; then
    assert_contains "$(record)" "env-repo=$EVIL_SLUG" \
      "MUTATION: expected an inherited GH_REPO to survive to the merge tool"
    return 0
  fi
  expect_code 0 "$code" "a hostile environment must not stop an otherwise valid merge: $out"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the resolved target decides, not GH_REPO"
  assert_contains "$(record)" "env-repo=$ORIGIN_SLUG" "GH_REPO is pinned to the resolved target"
  assert_contains "$(record)" "env-host=github.com" "GH_HOST is pinned to the only host this path resolves"
  assert_not_contains "$(record)" "$EVIL_SLUG" "nothing the environment named may reach the merge tool"

  # GIT_DIR overrides `git -C <dir>` outright, so an exported GIT_DIR makes every
  # remote lookup - the resolution AND the origin proof that checks it - read
  # another clone entirely. The two would agree with each other perfectly and pin
  # a merge to a repository that appears in no argument. Confirmed as a control
  # first, because a guard against a redirect that does not happen proves nothing.
  assert_contains "$(GIT_DIR="$ELSEWHERE/.git" git -C "$SOLO" remote get-url origin)" "$EVIL_SLUG" \
    "control: GIT_DIR really does override git -C - this is the red"
  reset_record
  out=$(GIT_DIR="$ELSEWHERE/.git" "$MERGE" t2env2 5 --project "$SOLO" 2>&1); code=$?
  expect_code 0 "$code" "an exported GIT_DIR must not redirect the merge: $out"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the named project directory decides which clone is read"
  assert_not_contains "$(record)" "$EVIL_SLUG" "no repository from another clone may reach the merge tool"
  pass "env-redirect: GH_REPO, GH_HOST and the git environment are pinned, never inherited"
}

# ============================================================================
case_git_config_substitution() {
  # THE SECOND ENVIRONMENT SUBSTITUTION, and the one the first scrub did not
  # cover. `env -u GIT_DIR ...` answers "which repository does git open?". It
  # does not answer "which configuration does git believe about it" - and a
  # remote URL is configuration. `url.<other>.insteadOf` rewrites a URL as git
  # hands it back, so a merge path that reads `remote get-url origin` reads the
  # substituted value, in BOTH the resolution and the origin proof that checks
  # it. They agree with each other perfectly, which is the exact failure the
  # scrub exists to defeat. This shipped on origin/main.
  #
  # TWO TRAPS LIVE IN THIS CASE, and both are asserted rather than described.
  #
  #   1. The payload is `insteadOf`, NOT a direct `remote.origin.url` override.
  #      The direct override through the same mechanism does not take effect, so
  #      a fix built by guessing which keys are dangerous tests the vector that
  #      cannot work, watches it fail, and ships with insteadOf still open. The
  #      control below proves this vector really does substitute the URL.
  #   2. `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` are unbounded in <n> and
  #      `env -u` takes no globs, so no fixed list of names can cover the family
  #      by construction. The high-index payload asserts the sweep is by PREFIX
  #      over the real environment, not by enumeration.
  #
  # AND THE GATE IS TWO-SIDED. Neutralising is not enough: something injecting
  # git configuration into a merge path is hostile or badly broken, and reading
  # the honest answer anyway is not a reason to continue. The resolution must be
  # UNCHANGED, and the merge command must REFUSE on its own named rail.
  #
  # Deliberately not the treatment env-redirect gives GH_REPO and GIT_DIR, which
  # are pinned and scrubbed but never refused on: those are set by ordinary
  # tooling for ordinary reasons (a git hook exports GIT_DIR to everything it
  # runs), so refusing on them would refuse ordinary merges. Nothing sets
  # GIT_CONFIG_COUNT by accident; its only purpose is to substitute
  # configuration, so its presence in a merge path IS the finding.
  local -a INJECT=(
    GIT_CONFIG_COUNT=1
    "GIT_CONFIG_KEY_0=url.https://github.com/$EVIL_SLUG.git.insteadOf"
    "GIT_CONFIG_VALUE_0=git@github.com:$ORIGIN_SLUG.git"
  )
  # The same payload at an index no list would have reached for. If this one
  # behaves differently from index 0, the fix enumerated names instead of
  # sweeping the family.
  local -a INJECT_HIGH=(
    GIT_CONFIG_COUNT=8
    "GIT_CONFIG_KEY_0=user.name" "GIT_CONFIG_VALUE_0=x"
    "GIT_CONFIG_KEY_1=user.name" "GIT_CONFIG_VALUE_1=x"
    "GIT_CONFIG_KEY_2=user.name" "GIT_CONFIG_VALUE_2=x"
    "GIT_CONFIG_KEY_3=user.name" "GIT_CONFIG_VALUE_3=x"
    "GIT_CONFIG_KEY_4=user.name" "GIT_CONFIG_VALUE_4=x"
    "GIT_CONFIG_KEY_5=user.name" "GIT_CONFIG_VALUE_5=x"
    "GIT_CONFIG_KEY_6=user.name" "GIT_CONFIG_VALUE_6=x"
    "GIT_CONFIG_KEY_7=url.https://github.com/$EVIL_SLUG.git.insteadOf"
    "GIT_CONFIG_VALUE_7=git@github.com:$ORIGIN_SLUG.git"
  )
  # The config FILES, chosen by an environment nothing can scrub: git needs a
  # HOME and every environment sets one, so an `insteadOf` in the global config
  # substitutes the URL exactly as the variables do. Closing the variables and
  # leaving this open would be a partial fix that reads as complete.
  local FAKEHOME="$TMP/gitconfig-home"
  mkdir -p "$FAKEHOME/git"
  cat > "$FAKEHOME/.gitconfig" <<EOF
[url "https://github.com/$EVIL_SLUG.git"]
	insteadOf = git@github.com:$ORIGIN_SLUG.git
EOF
  cp "$FAKEHOME/.gitconfig" "$FAKEHOME/git/config"

  local out code one

  if [ "$MUTATE" != 1 ]; then
    # CONTROLS FIRST. A guard against a substitution that does not happen proves
    # nothing, and this whole defect shipped because the vector was never run.
    assert_contains "$(env "${INJECT[@]}" git -C "$SOLO" remote get-url origin)" "$EVIL_SLUG" \
      "control: an injected insteadOf really does substitute the remote URL - this is the red"
    assert_contains "$(env "${INJECT[@]}" git -C "$SOLO" ls-remote --get-url origin)" "$EVIL_SLUG" \
      "control: ls-remote --get-url is substituted identically"
    assert_contains "$(env "${INJECT_HIGH[@]}" git -C "$SOLO" remote get-url origin)" "$EVIL_SLUG" \
      "control: the index is unbounded, so no fixed list of names can cover the family"
    assert_contains "$(env HOME="$FAKEHOME" git -C "$SOLO" remote get-url origin)" "$EVIL_SLUG" \
      "control: a global config chosen by HOME substitutes the URL the same way"
    assert_contains "$(env HOME=/nonexistent XDG_CONFIG_HOME="$FAKEHOME" git -C "$SOLO" remote get-url origin)" "$EVIL_SLUG" \
      "control: XDG_CONFIG_HOME chooses that same file"
    # The trap, asserted so a later reader cannot re-derive the wrong lesson: the
    # OBVIOUS payload is the one that does not work.
    assert_not_contains "$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url \
        "GIT_CONFIG_VALUE_0=https://github.com/$EVIL_SLUG.git" git -C "$SOLO" remote get-url origin)" \
      "$EVIL_SLUG" "trap: a direct remote.origin.url override does NOT take effect - only insteadOf does"

    # And the exact BOUNDARY of that trap, which is what makes it a trap rather
    # than a curiosity: repository config wins only over a key the repository
    # DEFINES. A remote the repository has never heard of is defined purely by
    # the injection, so it appears - and one phantom remote turns a sole-remote
    # clone into an ambiguous one, or supplies the only remote a clone with none
    # would otherwise have. Same family, same door, no insteadOf involved.
    assert_contains "$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.phantom.url \
        "GIT_CONFIG_VALUE_0=https://github.com/$EVIL_SLUG.git" git -C "$SOLO" remote)" \
      "phantom" "control: an injected remote the repository does not define really does appear"
    assert_not_contains "$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.phantom.url \
        "GIT_CONFIG_VALUE_0=https://github.com/$EVIL_SLUG.git" \
        bash -c '. "$1"; fm_merge_target_git "$2" remote' _ \
        "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")" \
      "phantom" "a phantom remote cannot be injected into the set the target is resolved from"

    # 1. NEUTRALISED. Every git read in the merge-target path goes through
    #    fm_merge_target_git, and the directory argument is the only thing that
    #    may decide what it answers.
    assert_contains "$(env "${INJECT[@]}" bash -c '. "$1"; fm_merge_target_git "$2" remote get-url origin' _ \
        "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")" "$ORIGIN_SLUG" \
      "the scrubbed read answers with the repository's own URL, not the substituted one"
    assert_contains "$(env "${INJECT_HIGH[@]}" bash -c '. "$1"; fm_merge_target_git "$2" remote get-url origin' _ \
        "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")" "$ORIGIN_SLUG" \
      "the sweep is by prefix, so a high GIT_CONFIG_KEY_<n> index is covered too"
    assert_contains "$(env HOME="$FAKEHOME" bash -c '. "$1"; fm_merge_target_git "$2" remote get-url origin' _ \
        "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")" "$ORIGIN_SLUG" \
      "the global config file is pinned away, so HOME cannot substitute the URL either"
    assert_contains "$(env HOME=/nonexistent XDG_CONFIG_HOME="$FAKEHOME" bash -c '. "$1"; fm_merge_target_git "$2" remote get-url origin' _ \
        "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")" "$ORIGIN_SLUG" \
      "nor can XDG_CONFIG_HOME"

    # 2. THE RESOLUTION IS UNCHANGED. The library neutralises rather than
    #    refuses, so a caller may still ask what a merge WOULD target in a
    #    hostile environment and get the honest answer.
    out=$(env "${INJECT[@]}" bash "$ROOT/bin/fm-merge-target-lib.sh" "$SOLO")
    assert_contains "$out" "OK	$ORIGIN_SLUG	sole-remote:origin" \
      "the resolved merge target is unchanged by the injection: $out"
    assert_not_contains "$out" "$EVIL_SLUG" "no substituted repository may appear in a resolution"
  fi

  # 3. THE GUARD REFUSES. Silent neutralisation is not the finding being
  #    handled; it is the finding being ignored.
  reset_record
  out=$(env "${INJECT[@]}" "$MERGE" t2gc 5 --project "$SOLO" 2>&1); code=$?
  if [ "$MUTATE" = 1 ]; then
    expect_code 0 "$code" "MUTATION: an injected git config expected to merge anyway"
    assert_contains "$(record)" "merged-into=$EVIL_SLUG" \
      "MUTATION: the substituted repository expected to reach the merge tool"
    return 0
  fi
  expect_code 1 "$code" "an injected git config must refuse the merge: $out"
  assert_contains "$out" "REFUSED[env/git-config-injected]" \
    "the refusal must name its own rail, not refuse generically: $out"
  assert_contains "$out" "GIT_CONFIG_KEY_0" \
    "the refusal must NAME what it found, so the caller can clean the environment: $out"
  assert_no_merge "an injected git config"

  # Every member of the family, one at a time - the file-selecting ones too,
  # which carry no key/value of their own and so would be invisible to a check
  # that only counted GIT_CONFIG_COUNT.
  for one in GIT_CONFIG_COUNT=0 GIT_CONFIG=/dev/null GIT_CONFIG_GLOBAL=/dev/null \
             GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
             GIT_CONFIG_PARAMETERS="'user.name=x'"; do
    reset_record
    out=$(env "$one" "$MERGE" t2gc1 5 --project "$SOLO" 2>&1); code=$?
    expect_code 1 "$code" "${one%%=*} in the environment must refuse: $out"
    assert_contains "$out" "REFUSED[env/git-config-injected]" \
      "${one%%=*} must refuse on the git-config rail: $out"
    assert_no_merge "${one%%=*}"
  done

  # 4. THE NEGATIVE CONTROL. A guard that refuses everything is not a guard.
  #    The honest environment still resolves and still merges, and HOME - which
  #    every environment sets and nothing can scrub - is never itself a refusal.
  reset_record
  out=$("$MERGE" t2gc2 5 --project "$SOLO" 2>&1); code=$?
  expect_code 0 "$code" "the honest environment must still merge: $out"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "the honest merge lands in origin"
  reset_record
  out=$(env HOME="$FAKEHOME" "$MERGE" t2gc3 5 --project "$SOLO" 2>&1); code=$?
  expect_code 0 "$code" "a substituting HOME is neutralised, not refused - every environment has a HOME: $out"
  assert_contains "$(record)" "merged-into=$ORIGIN_SLUG" "and the merge still lands in origin"
  assert_not_contains "$(record)" "$EVIL_SLUG" "nothing the environment substituted may reach the merge tool"

  pass "git-config-substitution: an injected git configuration cannot redirect a merge, and does not pass quietly"
}

# ============================================================================
case_origin_proof() {
  # Being NAMED proves nothing was inferred. It does not prove the name was
  # meant. A url, a remote name and a slug can all arrive from somewhere else -
  # a pasted link, a recorded meta line - so leaving origin takes a second word
  # that names no repository and so cannot itself redirect anything.
  refuses_with target/not-origin "a named non-origin target with no affirmation" -- \
    t2op 5 --project "$BOTH" --repo "$EVIL_SLUG"
  refuses_with target/not-origin "an upstream PR url with no affirmation" -- \
    t2op2 "https://github.com/$UPSTREAM_SLUG/pull/5" --project "$BOTH"
  refuses_with target/not-origin "--remote upstream with no affirmation" -- \
    t2op3 5 --project "$BOTH" --remote upstream
  # An origin that cannot be READ is the proof failing, not the proof passing.
  refuses_with target/origin-unprovable "a clone whose sole remote is not origin" -- \
    t2op4 5 --project "$NOORIGIN"
  [ "$MUTATE" = 1 ] && return 0

  # Affirmed, it merges - and never silently.
  reset_record
  out=$("$MERGE" t2op5 "https://github.com/$UPSTREAM_SLUG/pull/5" --project "$BOTH" --allow-non-origin 2>&1); code=$?
  expect_code 0 "$code" "an affirmed upstream contribution is legitimate and must merge: $out"
  assert_contains "$(record)" "merged-into=$UPSTREAM_SLUG" "the affirmed target is used"
  assert_contains "$out" "NOT this clone's origin" "leaving origin is announced even when affirmed"

  # --allow-non-origin names no repository, so it can never BE the redirect:
  # with it and nothing else, an ambiguous clone still refuses.
  reset_record
  out=$("$MERGE" t2op6 5 --project "$BOTH" --allow-non-origin 2>&1); code=$?
  expect_code 1 "$code" "the affirmation may not stand in for naming a target: $out"
  assert_contains "$out" "REFUSED[target/ambiguous-remotes]" "it affirms; it does not choose"
  assert_no_merge "affirmation without a named target"
  pass "origin-proof: the target must be proven equal to origin, or affirmed by a word only a human writes"
}

# ============================================================================
case_argv_egress() {
  # The last thing between a resolved target and an exec: re-read the finished
  # argv and prove it pins the target exactly once. Deliberately redundant with
  # everything above, because a construction that is correct today is not a
  # construction that stays correct.
  local t=$ORIGIN_SLUG
  if [ "$MUTATE" = 1 ]; then
    assert_contains "$(fm_merge_target_assert_argv "$t" pr merge 5 --repo "$EVIL_SLUG" || true)" "OK" \
      "MUTATION: expected an argv pinning the WRONG repository to be accepted"
    return 0
  fi

  assert_contains "$(fm_merge_target_assert_argv "$t" pr merge 5 --repo "$t")" "OK" \
    "the pinned argv is accepted"
  assert_contains "$(fm_merge_target_assert_argv "$t" pr merge 5 --repo "$t" --squash --body "merged the -R work")" "OK" \
    "an ordinary option value is data and is skipped, not read as a flag"
  # The egress check carries the same belt: it skips a value rather than reading
  # it as a flag, so a value that COULD be a repo flag is refused instead of
  # skipped - which is what keeps the skip honest if the arity model is wrong.
  assert_contains "$(fm_merge_target_assert_argv "$t" pr merge 5 --repo "$t" --body "-R$EVIL_SLUG" || true)" \
    "repo-flag-as-value" "a value that could name a repository is refused, never skipped"

  for bad in "no-repo-pin:pr merge 5" \
             "wrong-repo-pin:pr merge 5 --repo $EVIL_SLUG" \
             "extra-repo-flag:pr merge 5 --repo $t -R$EVIL_SLUG" \
             "extra-repo-flag:pr merge 5 --repo $t --repo=$EVIL_SLUG" \
             "extra-repo-flag:pr merge 5 --repo $t -dR$EVIL_SLUG" \
             "duplicate-repo-pin:pr merge 5 --repo $t --repo $t"; do
    reason=${bad%%:*}; av=${bad#*:}
    # shellcheck disable=SC2086  # deliberate word-splitting: each case is an argv
    got=$(fm_merge_target_assert_argv "$t" $av || true)
    assert_contains "$got" "$reason" "an argv that does not pin the target once must be refused: $av"
  done
  assert_contains "$(fm_merge_target_assert_argv "not a slug" pr merge 5 --repo "not a slug" || true)" \
    "bad-target" "a target that is not owner/name never reaches an argv at all"

  # End to end: the argv the real path builds passes its own check, and the
  # command --dry-run prints is the command that would have run.
  reset_record
  out=$("$MERGE" t2eg 5 --project "$SOLO" --dry-run -- --squash 2>/dev/null); code=$?
  expect_code 0 "$code" "--dry-run must succeed"
  assert_contains "$out" "gh-axi pr merge 5 --repo $ORIGIN_SLUG --squash" "the printed command carries exactly one pin"
  assert_contains "$out" "GH_REPO=$ORIGIN_SLUG" "the printed command shows the pinned environment"
  assert_no_merge "--dry-run"
  pass "argv-egress: the finished command is proved to pin the resolved target exactly once"
}

# ============================================================================
ALL_CASES="foreign-host pull-in-query pull-in-fragment trailing-path
           passthrough-repo-flag duplicate-repo-flag ambiguous-remotes
           env-redirect git-config-substitution origin-proof argv-egress"

run_case() {
  case "$1" in
    foreign-host)          case_foreign_host ;;
    pull-in-query)         case_pull_in_query ;;
    pull-in-fragment)      case_pull_in_fragment ;;
    trailing-path)         case_trailing_path ;;
    passthrough-repo-flag) case_passthrough_repo_flag ;;
    duplicate-repo-flag)   case_duplicate_repo_flag ;;
    ambiguous-remotes)     case_ambiguous_remotes ;;
    env-redirect)          case_env_redirect ;;
    git-config-substitution) case_git_config_substitution ;;
    origin-proof)          case_origin_proof ;;
    argv-egress)           case_argv_egress ;;
    *) fail "unknown case '$1'; known: $ALL_CASES" ;;
  esac
}

if [ $# -gt 0 ]; then
  for c in "$@"; do run_case "$c"; done
else
  # shellcheck disable=SC2086  # the case list is a deliberate word list
  for c in $ALL_CASES; do run_case "$c"; done
fi
