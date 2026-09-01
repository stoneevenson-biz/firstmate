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

# fm_merge_target_parse_pr_url <ref>: echo "<owner>/<repo><TAB><number>" for a
# canonical GitHub pull-request url, or return 1. ONE parse, BOTH values.
#
# WHY THIS IS ONE FUNCTION. Three separate wrong-merge defects came out of this
# file, and all three were the same shape: a value read from a reference that
# did not name it.
#   1. the number was matched out of any `*/pull/<digits>` string, so
#      `https://gitlab.com/other/proj/pull/23` lent its 23 to whichever
#      repository the remotes happened to resolve;
#   2. the number survived a url whose repository lost precedence to
#      `--remote`/`--repo`, merging PR 23 of a repository the url never named;
#   3. the slug was taken at the FIRST `/pull/` and the number at the LAST, so
#      `.../pull/12?next=/pull/99` merged PR 99 while every cross-check saw a
#      repository agreeing with itself.
# Each was patched where it was found, and the next one arrived through the next
# door. So the matching is gone. The url is taken apart in the order a url is
# actually defined - fragment, then query, then scheme, then host, then path -
# and BOTH answers come out of that single parse, which is why they can no
# longer disagree.
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
fm_merge_target_parse_pr_url() {
  local ref=${1:-} frag='' query='' rest owner repo lit num

  # 1. Fragment, then query - BEFORE anything looks at a path. A `/pull/` or a
  #    `/` living in either must never reach the path parser.
  case "$ref" in *'#'*) frag=${ref#*'#'}; ref=${ref%%'#'*} ;; esac
  case "$ref" in *'?'*) query=${ref#*'?'}; ref=${ref%%'?'*} ;; esac

  # 2. One reference, one pull request.
  case "$query$frag" in *'/pull/'*) return 1 ;; esac

  # 3. Scheme and host, matched exactly - not "contains github.com".
  case "$ref" in
    https://github.com/*) rest=${ref#https://github.com/} ;;
    http://github.com/*)  rest=${ref#http://github.com/} ;;
    *) return 1 ;;
  esac

  # 4. The path is exactly four segments. Five or more means something trails
  #    the pull request, and this refuses rather than deciding which part of a
  #    url the caller meant.
  case "$rest" in */*/*/*/*) return 1 ;; esac
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*};  rest=${rest#*/}
  lit=${rest%%/*};   num=${rest#*/}
  [ "$lit" = pull ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  fm_merge_target_valid_slug "$owner/$repo" || return 1

  printf '%s\t%s\n' "$owner/$repo" "$num"
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

  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
    if ! url=$(git -C "$dir" remote get-url "$want_remote" 2>/dev/null) || [ -z "$url" ]; then
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

  remotes=$(git -C "$dir" remote 2>/dev/null)
  count=0
  for name in $remotes; do count=$((count + 1)); done

  if [ "$count" -eq 0 ]; then
    printf 'NOREMOTE\n'
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    url=$(git -C "$dir" remote get-url "$remotes" 2>/dev/null || true)
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
    url=$(git -C "$dir" remote get-url "$name" 2>/dev/null || true)
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
  for name in $(git -C "$dir" remote 2>/dev/null); do
    url=$(git -C "$dir" remote get-url "$name" 2>/dev/null || true)
    if [ "$(fm_merge_target_from_url "$url" 2>/dev/null || true)" = "$slug" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# CLI form, for humans and for tests: same arguments, same exit codes.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_merge_target "${1:-.}" "${2:-}" "${3:-}" "${4:-}"
  exit $?
fi
