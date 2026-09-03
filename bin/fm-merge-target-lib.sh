#!/usr/bin/env bash
# fm-merge-target-lib.sh - the one implementation of "which GitHub repository
# does this merge land in?".
#
# THE DEFECT IT EXISTS FOR. A clone can carry more than one GitHub remote, and
# `~/firstmate` carries exactly two: `origin` (the captain's fork) and
# `upstream` (a public project). `gh`-shaped tooling does not merge into "the
# repo you are standing in" - it resolves a BASE repo from the remote set, and
# for PR operations on a fork it prefers the PARENT. On 2026-08-29 firstmate ran
# `gh-axi pr merge 5` with no repo argument in that clone and it resolved to
# upstream. It was a no-op only because that PR had already merged months
# earlier. Had it been open, a stranger's contribution would have landed in open
# source under the captain's name, with no step in between that named a repo.
#
# So the target is never inferred. It is resolved here, from a remote URL or
# from an argument the caller actually wrote, and passed to the tool as
# `--repo <owner/name>`. A tool that is told the repo cannot pick a different
# one.
#
# THE RULE, in precedence order, is the whole of this file's contract:
#
#   1. `--repo <owner/name>`  - the caller named the repository. Honoured
#                               verbatim; a malformed slug is refused, never
#                               "cleaned up".
#   2. `--remote <name>`      - the caller named a remote. Its URL is parsed to
#                               owner/name. A remote that does not exist, or
#                               whose URL is not a GitHub repository, refuses.
#   3. a full PR URL          - `https://github.com/<owner>/<repo>/pull/<n>`
#                               names its own repository. Nothing can be
#                               ambiguous about it, so it is an explicit choice
#                               like the two above.
#   4. exactly one remote     - one candidate is not a choice between
#                               candidates. Resolve from it.
#   5. more than one remote   - AMBIGUOUS. Refuse, naming every remote. A bare
#                               PR NUMBER exists independently in each of them,
#                               and nothing in the input says which one was
#                               meant. Deciding that is not mechanical, so this
#                               stops rather than guesses - which is the exact
#                               step the 2026-08-29 merge did not have.
#   6. no remotes at all      - nothing to merge against.
#
# Note what case 5 does NOT do: it does not quietly prefer `origin`. `origin` is
# a convention, not a statement, and the near-miss happened in a clone that had
# one. Once a second remote exists, the caller says which - and `--remote
# origin` is how they say "origin", which is then resolved from origin's own URL
# rather than from anything the tool believes.
#
# PURE AND SIDE-EFFECT FREE. It reads `git remote` in a directory and parses
# strings. It never fetches, never writes, and never invokes gh, gh-axi, or any
# network tool - so a caller may ask it what a merge WOULD target without any
# risk of performing one.
#
# Callers: bin/fm-merge-pr.sh. Also a CLI for humans and tests:
#   bash bin/fm-merge-target-lib.sh <repo-dir> [pr-ref] [owner/name] [remote]
# exit 0 resolved, 1 refused, 2 cannot inspect the directory.
#
# Output grammar, tab-separated, first line is the verdict:
#   OK<TAB><owner/name><TAB><source>     source: --repo | remote:<name> |
#                                                pr-url | sole-remote:<name>
#   AMBIGUOUS                            followed by one <name><TAB><owner/name
#                                        or raw url> row per remote
#   NOREMOTE                             the directory has no remotes
#   BADREPO<TAB><value>                  explicit --repo is not owner/name
#   BADREMOTE<TAB><name><TAB><detail>    named/sole remote unusable
#   NOTAGIT<TAB><dir>                    not a git work tree
#
# Spec: docs/specs/2026-08-31-merge-target-pin.md

# EVERY CHECK BELOW IS A BRACKET RANGE, AND A BRACKET RANGE IS A LOCALE
# QUESTION. `[A-Za-z0-9._/-]` does not mean the same set of bytes under every
# collation, so a slug or a path segment could be validated differently on two
# machines that are otherwise identical. The answers here decide where a merge
# lands, so they are asked in C and nowhere else.
#
# Deliberately NOT exported: bash applies an LC_* assignment to its own locale
# whether or not it is exported, so this settles the pattern matching in this
# file without changing the environment of anything this file's caller runs -
# which is what lets the "side-effect free" claim above stay true.
LC_ALL=C

# fm_merge_target_git <repo-dir> <git args>...: git, run against <repo-dir> and
# NOTHING ELSE.
#
# `git -C <dir>` is not the last word on which repository git reads. `GIT_DIR` in
# the environment overrides discovery entirely, so
# `GIT_DIR=/elsewhere/.git git -C /the/clone remote get-url origin` answers with
# ELSEWHERE's origin - verified, not theorised. That is a merge-target redirect
# that appears in no argument: the resolution and the origin proof would both
# read the attacker's clone, agree with each other perfectly, and pin a merge to
# a repository the caller never saw.
#
# THAT SCRUB ANSWERED THE WRONG HALF OF THE QUESTION, and shipped that way. It
# says which repository git OPENS. It does not say which configuration git
# BELIEVES about it - and a remote URL is configuration. `url.<other>.insteadOf`
# rewrites a URL as git hands it back, so
#
#   GIT_CONFIG_COUNT=1 \
#   GIT_CONFIG_KEY_0='url.https://github.com/attacker/evil.git.insteadOf' \
#   GIT_CONFIG_VALUE_0='https://github.com/the/honest-one.git' \
#   git remote get-url origin
#
# answers with the ATTACKER's URL, and did so straight through the `env -u` list
# below, because none of those names is in it. `git ls-remote --get-url` is
# rewritten identically. Same redirect, same two checks agreeing with each other
# perfectly, different door.
#
# TWO TRAPS, AND THE SHAPE OF THIS FUNCTION IS BOTH OF THEM.
#
#   1. A direct `remote.origin.url` override through the same mechanism does NOT
#      take effect - repository config wins. So a fix built by guessing which
#      keys are dangerous tests the vector that cannot work, watches it fail,
#      and ships with `insteadOf` and `pushInsteadOf` still open. No key is
#      judged here. The whole family goes.
#   2. `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` are UNBOUNDED in <n>, and
#      `env -u` takes no globs. A fixed list of names cannot cover the family by
#      construction, however carefully it is written - an enumeration is a
#      promise to have imagined every index, and there is no last index. So the
#      REAL environment is swept by prefix instead.
#
# AND THE CONFIG FILES, NOT ONLY THE CONFIG VARIABLES. `HOME` and
# `XDG_CONFIG_HOME` choose which file the global config is read from, and an
# `insteadOf` in that file substitutes the URL exactly as the variables do -
# verified the same way, a bypass of equal power.
#
# THE FILES ARE CLOSED AT THE ENVIRONMENT, NOT AT THE LOOKUP, and the difference
# is the whole of this paragraph. Disabling git's automatic global lookup with
# GIT_CONFIG_GLOBAL was tried first and is NOT sufficient: it stops git going
# looking for a global config, and does nothing about a `~` inside a path the
# REPOSITORY's own config names. `include.path = ~/.gitconfig` is an ordinary
# thing for a clone to carry, repository config is trusted here by design, and
# that `~` expands through HOME - so an attacker holding only the environment got
# the same insteadOf back through a file this path still trusts, and the
# resolution and the origin proof agreed on it exactly as before. Verified, after
# it walked through the first version of this fix.
#
# So HOME and XDG_CONFIG_HOME are PINNED at a path that cannot hold anything:
# `/dev/null` is a character device, so nothing can ever exist beneath it, and
# `~` resolves to a file git silently skips. That is a stronger promise than any
# directory we could create and hope stayed empty, and it needs no scratch state,
# which is what keeps the "pure and side-effect free" claim above true.
#
# It also settles the version question rather than documenting a hole in it.
# GIT_CONFIG_NOSYSTEM is ancient; GIT_CONFIG_SYSTEM and GIT_CONFIG_GLOBAL arrived
# in git 2.32, and an earlier version of this comment called the three
# "redundant across versions" while the global file stayed live below 2.32 - a
# known bypass described as belt and braces. It is not redundancy that closes
# that gap, it is the HOME pin, which no git version has ever ignored. The
# GIT_CONFIG_* pins stay because they are free and they say the intent locally,
# but nothing rests on them.
#
# Nothing this path reads - rev-parse, remote, remote get-url - wants global
# config; a global `insteadOf` a human relies on is deliberately not applied,
# because the merge target must be the URL the repository RECORDS rather than a
# rewrite of it. What goes with it is `safe.directory`, which git accepts only
# from global and system config: a repository that needed it now fails the read,
# surfacing as NOTAGIT and refusing - a failure, never a wrong merge.
#
# HOME is still NEUTRALISED rather than refused on, unlike the GIT_CONFIG family.
# Every environment has a HOME; refusing on one would refuse every merge.
#
# WHAT THIS DOES NOT DEFEND, AND WHY THE LINE IS HERE. Everything above is about
# environment that changes git's INTERPRETATION of a repository - which one it
# opens, which configuration it applies. It is not about environment that
# replaces the BINARY. `git` below is resolved through the inherited PATH, so a
# fake `git` first on PATH answers every question this path asks and makes the
# resolution and the origin proof agree on the attacker's repository, exactly as
# an insteadOf would have. That is real and it is gated as a boundary rather than
# described.
#
# It is not closed because it cannot be, from in here: substituting the
# executable is arbitrary code execution, and the same environment could replace
# bash or bin/fm-merge-pr.sh itself. Pinning git to a fixed absolute path either
# refuses on machines whose git lives in /opt/homebrew, ~/.nix-profile or a
# version manager, or falls back to PATH and closes nothing - raising the
# apparent strength of the claim without changing what it rests on. The threat
# model is written down instead:
# docs/specs/2026-09-02-merge-target-git-config.md.
#
# NEUTRALISE HERE, REFUSE AT THE VERB. This file stays pure and side-effect free,
# so a caller may ask what a merge WOULD target in a hostile environment and get
# the honest answer. bin/fm-merge-pr.sh reads fm_merge_target_git_config_env
# itself and refuses, because reading the right value anyway is not a reason to
# run a merge in an environment that is substituting git configuration.
#
# Spec: docs/specs/2026-09-02-merge-target-git-config.md

# A home directory that cannot exist. `/dev/null` is a character device, so no
# path beneath it can ever be created - which makes this a stronger guarantee
# than an empty directory, and one that needs no scratch state to maintain.
FM_MERGE_TARGET_NO_HOME=/dev/null/fm-merge-target-has-no-home

# fm_merge_target_git_config_env: echo, one per line, the name of every
# GIT_CONFIG* variable this shell can see - swept BY PREFIX over the real
# environment, never matched against a list, for trap 2 above. Empty output
# means nothing is substituting git configuration.
#
# Pure: it reads names and prints them. What to DO about them is the caller's,
# which is what lets the library neutralise while the merge verb refuses.
fm_merge_target_git_config_env() {
  local name
  for name in "${!GIT_CONFIG@}"; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done
}

fm_merge_target_git() {
  local dir=${1:-}; shift
  local name
  local -a scrub=()
  for name in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
              GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
              GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
              "${!GIT_CONFIG@}"; do
    [ -n "$name" ] || continue
    scrub+=(-u "$name")
  done
  env "${scrub[@]}" \
      HOME="$FM_MERGE_TARGET_NO_HOME" XDG_CONFIG_HOME="$FM_MERGE_TARGET_NO_HOME" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null \
      git -C "$dir" "$@"
}

# fm_merge_target_valid_slug <value>: true when <value> is exactly owner/name
# with no path separators beyond the one and no characters GitHub does not use.
fm_merge_target_valid_slug() {
  local slug=${1:-} owner name
  case "$slug" in
    */*/*) return 1 ;;
    */*) : ;;
    *) return 1 ;;
  esac
  case "$slug" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  owner=${slug%%/*}
  name=${slug#*/}
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  # `.` and `..` pass the character class but are not GitHub names - they are
  # path-traversal artefacts, and the contract says a malformed slug is refused
  # rather than cleaned up. Nor may a segment lead with `-`, which GitHub does
  # not allow and which reads as a flag anywhere a slug is interpolated.
  case "$owner" in .|..|-*) return 1 ;; esac
  case "$name" in .|..|-*) return 1 ;; esac
  return 0
}

# fm_merge_target_redact_url <url>: echo <url> with any userinfo replaced by
# `***`. A remote that failed to parse is printed raw so the reader can see WHY
# it was no help, and a non-GitHub remote's URL can carry a token; the fleet's
# rule is that secrets are never printed, so the reason survives and the
# credential does not.
fm_merge_target_redact_url() {
  local url=${1:-} scheme rest
  case "$url" in
    *://*)
      scheme=${url%%://*}
      rest=${url#*://}
      case "${rest%%/*}" in
        *@*) printf '%s://***@%s\n' "$scheme" "${rest#*@}"; return 0 ;;
      esac ;;
    # scp-style `user@host:path` has no scheme but carries userinfo just the
    # same, so it needs the same treatment; a bare local path has neither.
    *@*:*) printf '***@%s\n' "${url#*@}"; return 0 ;;
  esac
  printf '%s\n' "$url"
}

# fm_merge_target_shquote <word>: echo <word> safely re-runnable in a shell.
# Only used to PRINT a command (--dry-run), never to build one - the real
# invocation passes an argv, which needs no quoting. But a printed command that
# the caller cannot paste back is not the "exact command" it claims to be.
fm_merge_target_shquote() {
  case "${1:-}" in
    '') printf "''" ;;
    *[!A-Za-z0-9._/:=@-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_merge_target_from_url <remote-url>: echo owner/name for a GitHub remote in
# any of the forms git actually stores, or return 1. Anything not on github.com
# - a file:// fixture, a GitLab remote, a local path - is deliberately not a
# GitHub repository and is refused rather than approximated.
fm_merge_target_from_url() {
  local url=${1:-} path rest
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://*|https://*|http://*|git://*)
      rest=${url#*://}
      # Strip userinfo, but ONLY when the '@' falls inside the AUTHORITY - the
      # part before the first '/'. Matching '*@github.com/*' against the whole
      # URL instead was a fail-open: `https://evil.example.com/x@github.com/o/r`
      # is not a GitHub remote, yet the '@github.com/' in its PATH made it read
      # as one and resolved to the real repository `o/r`.
      case "${rest%%/*}" in
        *@*) rest=${rest#*@} ;;
      esac
      # No port form: `github.com:22/o/r` refuses rather than resolves. Refusing
      # an exotic remote costs a `--repo`; guessing past one costs a merge.
      case "$rest" in
        github.com/*) path=${rest#github.com/} ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  fm_merge_target_valid_slug "$path" || return 1
  printf '%s\n' "$path"
}

# fm_merge_target_parse_pr_ref <ref>: THE parse. ONE walk of the reference,
# BOTH answers, and - when it refuses - the NAME of the rail that refused it.
#
# WHY THIS IS ONE FUNCTION. Four wrong-merge defects came out of this file, and
# all four were the same shape: a value read from a reference that did not name
# it.
#   1. the number was matched out of any `*/pull/<digits>` string, so
#      `https://gitlab.com/other/proj/pull/23` lent its 23 to whichever
#      repository the remotes happened to resolve;
#   2. the number survived a url whose repository lost precedence to
#      `--remote`/`--repo`, merging PR 23 of a repository the url never named;
#   3. the slug was taken at the FIRST `/pull/` and the number at the LAST, so
#      `.../pull/12?next=/pull/99` merged PR 99 while every cross-check saw a
#      repository agreeing with itself;
#   4. a `-Rowner/repo` after `--` slipped past a blocklist that knew only the
#      detached forms, and `gh` keeps the LAST repo flag it is given.
# Each was patched where it was found, and the next one arrived through the next
# door. So the matching is gone. The url is taken apart in the order a url is
# actually defined - fragment, then query, then scheme, then host, then path -
# and BOTH answers come out of that single parse, which is why they can no
# longer disagree.
#
# WHY IT NAMES ITS REASON. A refusal that only says "not a pull request I can
# name" is a refusal nobody can gate. Each rail below has its own token, so a
# test can prove that THIS vector is what stopped THIS input, and a later refactor
# that quietly reopens one fails a named gate rather than passing a generic one.
#
# WHAT IS ACCEPTED is exactly one shape:
#     http(s)://github.com/<owner>/<repo>/pull/<digits>
# with an optional query and fragment that name no second pull request. Nothing
# trailing: `/files`, `/commits`, `/1/files` are refused rather than trimmed,
# because trimming is how a url that says one thing came to mean another. And a
# reference names exactly ONE pull request - if the query or the fragment
# mentions a second, the reference is ambiguous about its own subject, so it
# stops, the same way an ambiguous remote set does.
#
# Refusing a url a human could have meant costs one trimmed paste. Accepting one
# costs a merge, and a merge does not come back.
#
# Emits, and returns 0 / 1:
#   OK<TAB><owner/name><TAB><number>
#   ERR<TAB><reason>   reason in: not-a-url | foreign-host |
#                      second-pull-in-query | second-pull-in-fragment |
#                      trailing-path | not-a-pull-path | non-numeric-number |
#                      bad-slug
fm_merge_target_parse_pr_ref() {
  local ref=${1:-} frag='' query='' rest owner repo lit num

  # 1. Fragment, then query - BEFORE anything looks at a path. A `/pull/` or a
  #    `/` living in either must never reach the path parser.
  case "$ref" in *'#'*) frag=${ref#*'#'}; ref=${ref%%'#'*} ;; esac
  case "$ref" in *'?'*) query=${ref#*'?'}; ref=${ref%%'?'*} ;; esac

  # 2. One reference, one pull request - and each half says which half it was.
  case "$query" in *'/pull/'*) printf 'ERR\tsecond-pull-in-query\n'; return 1 ;; esac
  case "$frag"  in *'/pull/'*) printf 'ERR\tsecond-pull-in-fragment\n'; return 1 ;; esac

  # 3. Scheme and host, matched exactly - not "contains github.com". Anything
  #    else carrying a scheme is a foreign origin: another host, or a scheme
  #    (ssh://, git://) that is not how a pull request is addressed.
  case "$ref" in
    https://github.com/*) rest=${ref#https://github.com/} ;;
    http://github.com/*)  rest=${ref#http://github.com/} ;;
    *://*) printf 'ERR\tforeign-host\n'; return 1 ;;
    *)     printf 'ERR\tnot-a-url\n'; return 1 ;;
  esac

  # 4. The path is EXACTLY four segments. Five or more means something trails
  #    the pull request, and this refuses rather than deciding which part of a
  #    url the caller meant; fewer is not a pull-request path at all.
  case "$rest" in
    */*/*/*/*) printf 'ERR\ttrailing-path\n'; return 1 ;;
    */*/*/*)   : ;;
    *)         printf 'ERR\tnot-a-pull-path\n'; return 1 ;;
  esac
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*};  rest=${rest#*/}
  lit=${rest%%/*};   num=${rest#*/}
  [ "$lit" = pull ] || { printf 'ERR\tnot-a-pull-path\n'; return 1; }
  case "$num" in ''|*[!0-9]*) printf 'ERR\tnon-numeric-number\n'; return 1 ;; esac
  fm_merge_target_valid_slug "$owner/$repo" || { printf 'ERR\tbad-slug\n'; return 1; }

  printf 'OK\t%s/%s\t%s\n' "$owner" "$repo" "$num"
}

# fm_merge_target_pr_ref_reason <ref>: the rail that refused <ref>, or nothing
# when it parses. A thin read of the one parse above - never a second walk.
fm_merge_target_pr_ref_reason() {
  local parsed
  parsed=$(fm_merge_target_parse_pr_ref "${1:-}") && return 1
  printf '%s\n' "${parsed#ERR	}"
  return 0
}

# fm_merge_target_parse_pr_url <ref>: echo "<owner>/<repo><TAB><number>" for a
# canonical GitHub pull-request url, or return 1. The historical shape of the
# one parse above, kept because it is what every caller and gate already asks.
fm_merge_target_parse_pr_url() {
  local parsed
  parsed=$(fm_merge_target_parse_pr_ref "${1:-}") || return 1
  printf '%s\n' "${parsed#OK	}"
}

# fm_merge_target_from_pr_url <ref>: the repository half of that one parse.
fm_merge_target_from_pr_url() {
  local parsed
  parsed=$(fm_merge_target_parse_pr_url "${1:-}") || return 1
  printf '%s\n' "${parsed%%	*}"
}

# fm_merge_target_pr_number <ref>: echo the PR number for a bare number, or the
# number half of that same one parse. Nothing else is a pull-request reference.
fm_merge_target_pr_number() {
  local ref=${1:-} parsed
  case "$ref" in
    '') return 1 ;;
    *[!0-9]*) : ;;
    *) printf '%s\n' "$ref"; return 0 ;;
  esac
  parsed=$(fm_merge_target_parse_pr_url "$ref") || return 1
  printf '%s\n' "${parsed#*	}"
}

# fm_merge_target <repo-dir> [pr-ref] [explicit-repo] [explicit-remote]
# Emits the grammar above; returns 0 resolved, 1 refused, 2 cannot inspect.
fm_merge_target() {
  local dir=${1:-} pr=${2:-} want_repo=${3:-} want_remote=${4:-}
  local url slug remotes count name

  if ! fm_merge_target_git "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'NOTAGIT\t%s\n' "$dir"
    return 2
  fi

  if [ -n "$want_repo" ]; then
    if fm_merge_target_valid_slug "$want_repo"; then
      printf 'OK\t%s\t--repo\n' "$want_repo"
      return 0
    fi
    printf 'BADREPO\t%s\n' "$want_repo"
    return 1
  fi

  if [ -n "$want_remote" ]; then
    if ! url=$(fm_merge_target_git "$dir" remote get-url "$want_remote" 2>/dev/null) || [ -z "$url" ]; then
      printf 'BADREMOTE\t%s\tno such remote\n' "$want_remote"
      return 1
    fi
    if ! slug=$(fm_merge_target_from_url "$url"); then
      printf 'BADREMOTE\t%s\t%s\n' "$want_remote" "$(fm_merge_target_redact_url "$url")"
      return 1
    fi
    printf 'OK\t%s\tremote:%s\n' "$slug" "$want_remote"
    return 0
  fi

  if [ -n "$pr" ] && slug=$(fm_merge_target_from_pr_url "$pr"); then
    printf 'OK\t%s\tpr-url\n' "$slug"
    return 0
  fi

  remotes=$(fm_merge_target_git "$dir" remote 2>/dev/null)
  count=0
  for name in $remotes; do count=$((count + 1)); done

  if [ "$count" -eq 0 ]; then
    printf 'NOREMOTE\n'
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    url=$(fm_merge_target_git "$dir" remote get-url "$remotes" 2>/dev/null || true)
    if ! slug=$(fm_merge_target_from_url "$url"); then
      printf 'BADREMOTE\t%s\t%s\n' "$remotes" "$(fm_merge_target_redact_url "$url")"
      return 1
    fi
    printf 'OK\t%s\tsole-remote:%s\n' "$slug" "$remotes"
    return 0
  fi

  # More than one remote and nothing in the input chose between them. Name every
  # candidate so the refusal is actionable rather than merely negative.
  printf 'AMBIGUOUS\n'
  for name in $remotes; do
    url=$(fm_merge_target_git "$dir" remote get-url "$name" 2>/dev/null || true)
    if slug=$(fm_merge_target_from_url "$url"); then
      printf '%s\t%s\n' "$name" "$slug"
    else
      printf '%s\t%s\n' "$name" "$(fm_merge_target_redact_url "$url")"
    fi
  done
  return 1
}

# fm_merge_target_pr_slug_conflict <target> <pr-ref>: echo the repository the
# ref NAMES when that is not <target>, and return 0 - a conflict exists. Return 1
# when there is none: a bare number makes no claim about a repository, and a URL
# naming <target> agrees with it.
#
# Restricting the PR number to a VALIDATED github.com url closed the foreign-host
# half of this hole; this closes the rest of it. A url for `other/proj` combined
# with `--remote origin` still passed both checks on its own terms - the url was
# a well-formed GitHub PR reference, and the target was explicitly named - and
# then merged PR 23 of the CAPTAIN'S repository, because only the number
# survived the url. Two statements about one merge that disagree do not average
# out into an answer: PR 23 in `other/proj` is a different pull request from PR
# 23 in `stoneevenson-biz/firstmate`, and nothing in the input says which the
# caller meant. So it stops, exactly as an ambiguous remote set does.
fm_merge_target_pr_slug_conflict() {
  local target=${1:-} ref=${2:-} slug
  slug=$(fm_merge_target_from_pr_url "$ref" 2>/dev/null) || return 1
  [ "$slug" = "$target" ] && return 1
  printf '%s\n' "$slug"
  return 0
}

# fm_merge_target_remote_for <repo-dir> <owner/name>: echo the name of the
# remote whose URL is that repository, or nothing. Used only to make a message
# more informative ("that is remote 'upstream'"); it never decides anything.
fm_merge_target_remote_for() {
  local dir=${1:-} slug=${2:-} name url
  for name in $(fm_merge_target_git "$dir" remote 2>/dev/null); do
    url=$(fm_merge_target_git "$dir" remote get-url "$name" 2>/dev/null || true)
    if [ "$(fm_merge_target_from_url "$url" 2>/dev/null || true)" = "$slug" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# --- the merge command's own argv: an ALLOWLIST, and a proof --------------
#
# WHY AN ALLOWLIST. The passthrough after `--` was guarded by a blocklist of the
# repo-flag spellings someone had thought of - `-R`, `--repo`, `--repo=`, `-R=`.
# `gh` keeps the LAST repo flag it sees, so ONE spelling nobody listed is a
# merge into a repository nobody named, and `-Rowner/repo` was that spelling.
# A blocklist is a promise to have imagined every input; an allowlist is a
# promise to have imagined every OUTPUT, and there are far fewer of those.
#
# So: the merge argv is CONSTRUCTED from validated components - a number that is
# digits, a target that is a validated slug, and passthrough options drawn from
# the fixed sets below. Nothing is sanitised, because nothing caller-supplied is
# interpolated in the first place.
#
# SHORT FLAGS ARE REFUSED WHOLESALE, and that is the rule rather than a special
# case: a short flag may cluster (`-dR owner/repo`) and may carry its value
# attached (`-Rowner/repo`), so "does this short flag name a repository?" is the
# question the blocklist kept getting wrong. The long form of every option below
# is accepted instead, which costs a caller four characters and closes the family.
#
# THE SETS ARE FIRSTMATE'S SANCTION, NOT A MIRROR OF `gh pr merge --help`. An
# option gh grows that is not listed here is REFUSED, with a message saying to
# add it. A stale list therefore costs one refusal and one commit; a list that
# tried to track gh automatically would cost a merge the day gh grew a flag that
# names a repository.
FM_MERGE_PASSTHROUGH_BARE=' --squash --merge --rebase --delete-branch --admin --auto --disable-auto '
FM_MERGE_PASSTHROUGH_VALUED=' --body --body-file --subject --match-head-commit --author-email '

# fm_merge_target_passthrough_kind <arg>: bare | valued | '' (not allowlisted).
fm_merge_target_passthrough_kind() {
  local name=${1:-}
  name=${name%%=*}
  case "$FM_MERGE_PASSTHROUGH_BARE"   in *" $name "*) printf 'bare\n';   return 0 ;; esac
  case "$FM_MERGE_PASSTHROUGH_VALUED" in *" $name "*) printf 'valued\n'; return 0 ;; esac
  return 1
}

# fm_merge_target_names_repo <arg>: true when <arg> could name a repository to a
# gh-shaped CLI, in ANY spelling. Detached (`--repo`, `-R`), inline (`--repo=x`,
# `-R=x`), ATTACHED (`-Rx`), or CLUSTERED (`-dRx`). The attached and clustered
# forms are the ones a blocklist of literal strings cannot express, which is why
# this asks a question about the SHAPE instead of comparing against a list.
fm_merge_target_names_repo() {
  case "${1:-}" in
    --repo|--repo=*) return 0 ;;
    --*)             return 1 ;;
    -R*)             return 0 ;;
    -[!-]*)          case "$1" in *R*) return 0 ;; esac; return 1 ;;
  esac
  return 1
}

# fm_merge_target_check_passthrough <arg>...: OK, or ERR<TAB><reason><TAB><arg>.
# reasons: repo-flag | repo-flag-as-value | short-flag | unknown-flag | positional
#          | value-on-bare-flag | empty-value | missing-value
fm_merge_target_check_passthrough() {
  local arg kind want=''
  for arg in ${@+"$@"}; do
    if [ -n "$want" ]; then
      # THE ARITY DECLARATION ABOVE IS OURS, NOT GH'S. This file deliberately
      # does not mirror `gh pr merge --help`, so "how many words does --body
      # take?" is a belief about a third-party CLI rather than a fact this code
      # can check - and if that belief is ever wrong, a repo flag sitting where
      # we expected a value would be a flag to gh while being skipped here. So a
      # value that could name a repository refuses too, which makes the arity
      # model no longer load-bearing. It costs a merge-commit body that reads
      # exactly like a repo flag, and nothing else.
      if fm_merge_target_names_repo "$arg"; then
        printf 'ERR\trepo-flag-as-value\t%s\n' "$arg"; return 1
      fi
      want=''; continue
    fi
    if fm_merge_target_names_repo "$arg"; then
      printf 'ERR\trepo-flag\t%s\n' "$arg"; return 1
    fi
    case "$arg" in
      --*) : ;;
      -?*) printf 'ERR\tshort-flag\t%s\n' "$arg"; return 1 ;;
      *)   printf 'ERR\tpositional\t%s\n' "$arg"; return 1 ;;
    esac
    if ! kind=$(fm_merge_target_passthrough_kind "$arg"); then
      printf 'ERR\tunknown-flag\t%s\n' "$arg"; return 1
    fi
    case "$kind:$arg" in
      bare:*=*)   printf 'ERR\tvalue-on-bare-flag\t%s\n' "$arg"; return 1 ;;
      valued:*=)  printf 'ERR\tempty-value\t%s\n' "$arg"; return 1 ;;
      valued:*=*)
        # Same rule for the inline form: `--body=-Rowner/repo` is one word here
        # and would be one word to gh too, but only while our arity belief holds.
        if fm_merge_target_names_repo "${arg#*=}"; then
          printf 'ERR\trepo-flag-as-value\t%s\n' "$arg"; return 1
        fi ;;
      valued:*)   want=$arg ;;
    esac
  done
  [ -z "$want" ] || { printf 'ERR\tmissing-value\t%s\n' "$want"; return 1; }
  printf 'OK\n'
}

# fm_merge_target_assert_argv <target> <argv>...: the LAST thing between a
# resolved target and an exec. It re-reads the argv that is about to run and
# proves the pin is in it, exactly once, with exactly the resolved value.
#
# Everything above decides; this one checks the decision survived. It is
# deliberately redundant with the allowlist - the allowlist can be refactored,
# a flag can be added to the wrong set, an argument can be appended by a future
# caller, and none of that can get past a check that reads the finished argv and
# asks the only question that matters: does this command name the repository we
# resolved, and nothing else? A refusal here is an internal error, not caller
# error, and says so.
#
# Emits OK, or ERR<TAB><reason><TAB><detail>. reasons: bad-target | no-repo-pin |
# duplicate-repo-pin | wrong-repo-pin | extra-repo-flag | repo-flag-as-value
fm_merge_target_assert_argv() {
  local target=${1:-}; shift
  local seen=0 i=0 n arg next kind
  local -a argv=(${@+"$@"})

  if ! fm_merge_target_valid_slug "$target"; then
    printf 'ERR\tbad-target\t%s\n' "$target"; return 1
  fi

  n=${#argv[@]}
  while [ "$i" -lt "$n" ]; do
    arg=${argv[i]}
    if [ "$arg" = --repo ]; then
      next=${argv[$((i + 1))]:-}
      if [ "$next" != "$target" ]; then
        printf 'ERR\twrong-repo-pin\t%s\n' "$next"; return 1
      fi
      seen=$((seen + 1))
      if [ "$seen" -gt 1 ]; then
        printf 'ERR\tduplicate-repo-pin\t%s\n' "$arg"; return 1
      fi
      i=$((i + 2)); continue
    fi
    if fm_merge_target_names_repo "$arg"; then
      printf 'ERR\textra-repo-flag\t%s\n' "$arg"; return 1
    fi
    # An allowlisted option's VALUE is data to gh, so it is skipped here rather
    # than read as a flag. But the arity that says "the next word is a value" is
    # this file's belief about gh, not something it can verify - so a value that
    # could itself name a repository is refused instead of skipped. That is what
    # keeps this check honest even if the belief is wrong.
    if kind=$(fm_merge_target_passthrough_kind "$arg"); then
      case "$arg" in
        *=*) : ;;                                   # value is inline; one word
        *)
          if [ "$kind" = valued ]; then
            next=${argv[$((i + 1))]:-}
            if fm_merge_target_names_repo "$next"; then
              printf 'ERR\trepo-flag-as-value\t%s\n' "$next"; return 1
            fi
            i=$((i + 2)); continue
          fi ;;
      esac
    fi
    i=$((i + 1))
  done

  [ "$seen" -eq 1 ] || { printf 'ERR\tno-repo-pin\t%s\n' "$seen"; return 1; }
  printf 'OK\n'
}

# fm_merge_target_origin_slug <repo-dir>: echo the owner/name of the `origin`
# remote, or return 1 when there is none or it is not a GitHub repository.
# This is the repository a clone is OF, and it is what a merge is proved against.
fm_merge_target_origin_slug() {
  local url
  url=$(fm_merge_target_git "${1:-}" remote get-url origin 2>/dev/null) || return 1
  fm_merge_target_from_url "$url"
}

# CLI form, for humans and for tests: same arguments, same exit codes.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_merge_target "${1:-.}" "${2:-}" "${3:-}" "${4:-}"
  exit $?
fi
