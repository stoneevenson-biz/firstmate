#!/usr/bin/env bash
# fm-merge-pr.sh - merge a task's pull request into a repository that was named,
# never one that was inferred.
#
# This is the fleet's only merge path for a PR-based ship task. It exists
# because the previous one was "firstmate runs `gh-axi pr merge <n>` by hand",
# and that command does not name a repository: `gh`-shaped tooling resolves a
# base repo from the clone's remote set and prefers the parent of a fork for PR
# operations. On 2026-08-29 that resolved `gh-axi pr merge 5` in `~/firstmate` -
# a clone with `origin` (the captain's fork) and `upstream` (a public project) -
# to UPSTREAM. It was a no-op only because that PR had merged months earlier.
#
# So this script resolves the target first, with bin/fm-merge-target-lib.sh, and
# passes it as `--repo <owner/name>`. The rule and its precedence live in that
# library and are not restated here. Two consequences worth knowing at the call
# site:
#   - a bare PR number in a clone with more than one remote REFUSES, naming
#     every remote, because that number exists in each of them;
#   - a full PR URL names its own repository, so `bin/fm-merge-pr.sh <id>` with
#     the URL already recorded in `state/<id>.meta` by fm-pr-check just works.
#
# Usage:
#   fm-merge-pr.sh <task-id> [<pr-url-or-number>] [flags] [-- <gh-axi args>...]
#     --repo <owner/name>   merge into this repository, verbatim
#     --remote <name>       merge into the repository this remote points at
#     --project <dir>       repo to resolve remotes from (default: meta project=)
#     --dry-run             print the exact merge command and exit, running none
# Anything after `--` is passed through to `gh-axi pr merge`, but as an
# ALLOWLIST: --merge/--squash/--rebase/--auto/--delete-branch, and
# --method/--body/--body-file/--subject with a value. Everything else is
# REFUSED by name. gh keeps the LAST repo flag it sees, so a passthrough
# `--repo x`, `-R x` or `-Rowner/repo` would silently override the pin while
# stderr still announced the resolved target - and blocking spellings one at a
# time lost that race twice.
#
# Merge authority is unchanged: AGENTS.md still requires the captain's word (or
# an authorized `yolo` posture). This script decides WHERE a merge lands, never
# WHETHER it may happen.
#
# Spec: docs/specs/2026-08-31-merge-target-pin.md
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

# shellcheck source=bin/fm-merge-target-lib.sh
. "$SCRIPT_DIR/fm-merge-target-lib.sh"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
usage() {
  echo "usage: fm-merge-pr.sh <task-id> [<pr-url-or-number>] [--repo <owner/name>] [--remote <name>] [--project <dir>] [--dry-run] [-- <gh-axi args>]" >&2
  exit 2
}

ID=""; PR=""; WANT_REPO=""; WANT_REMOTE=""; PROJ=""; DRYRUN=0
WANT_REPO_SET=0; WANT_REMOTE_SET=0; PROJ_SET=0
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; WANT_REPO=$2; WANT_REPO_SET=1; shift 2 ;;
    --repo=*) WANT_REPO=${1#--repo=}; WANT_REPO_SET=1; shift ;;
    --remote) [ $# -ge 2 ] || usage; WANT_REMOTE=$2; WANT_REMOTE_SET=1; shift 2 ;;
    --remote=*) WANT_REMOTE=${1#--remote=}; WANT_REMOTE_SET=1; shift ;;
    --project) [ $# -ge 2 ] || usage; PROJ=$2; PROJ_SET=1; shift 2 ;;
    --project=*) PROJ=${1#--project=}; PROJ_SET=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --)
      # PASSTHROUGH IS AN ALLOWLIST, not a list of things to block.
      #
      # It began as a blocklist of repo flags, and that was defeated twice: gh
      # keeps the LAST repo flag it sees, so a passthrough one wins over the pin
      # while stderr still announces the resolved target. First `--repo x` and
      # `-R x`, which the blocklist then named; then `-Rowner/repo`, the ATTACHED
      # short form, which it did not. Same defect, one spelling further along -
      # and the next spelling would have been the next reject.
      #
      # So the question is no longer "which flags are dangerous" (unknowable:
      # `--repo`, `-R`, `-Rx`, and a host flag would redirect the whole API) but
      # "which flags does `gh-axi pr merge` actually take". That list is short,
      # documented by the binary, and anything outside it is refused by name.
      # A new merge flag costs one line here; the alternative cost is a merge in
      # a repository nobody named.
      shift
      expect_value=0
      while [ $# -gt 0 ]; do
        if [ "$expect_value" = 1 ]; then
          expect_value=0; EXTRA+=("$1"); shift; continue
        fi
        case "$1" in
          # Named first so the repo case keeps its own diagnosis. `-R*` covers
          # `-R`, `-R=x` and the attached `-Rowner/repo` alike.
          -R*|--repo|--repo=*)
            echo "REFUSED: '$1' after -- would override the pinned merge target (gh takes the LAST repo flag)." >&2
            echo "         Name the repository with this script's own --repo/--remote, before the --." >&2
            exit 1 ;;
          --merge|--squash|--rebase|--auto|--delete-branch)
            EXTRA+=("$1"); shift ;;
          --method=*|--body=*|--body-file=*|--subject=*)
            EXTRA+=("$1"); shift ;;
          --method|--body|--body-file|--subject)
            [ $# -ge 2 ] || { echo "REFUSED: '$1' after -- needs a value." >&2; exit 1; }
            expect_value=1; EXTRA+=("$1"); shift ;;
          *)
            echo "REFUSED: '$1' is not a 'gh-axi pr merge' option this script passes through." >&2
            echo "         Allowed: --merge --squash --rebase --auto --delete-branch" >&2
            echo "                  --method --body --body-file --subject (each with a value)" >&2
            echo "         Passthrough is an allowlist on purpose: a flag nobody vetted can" >&2
            echo "         redirect the merge, which is the whole thing this script prevents." >&2
            exit 1 ;;
        esac
      done ;;
    -*) usage ;;
    *)
      if [ -z "$ID" ]; then ID=$1
      elif [ -z "$PR" ]; then PR=$1
      else usage
      fi
      shift ;;
  esac
done
[ -n "$ID" ] || usage

# An EMPTY flag value is not a choice, and must never be read as "no flag given"
# - that would silently hand the decision back to the remote set the caller was
# in the middle of overriding. `--repo=` is a typo, not consent.
for empty_flag in "--repo:$WANT_REPO_SET:$WANT_REPO" "--remote:$WANT_REMOTE_SET:$WANT_REMOTE" "--project:$PROJ_SET:$PROJ"; do
  flag=${empty_flag%%:*}; rest=${empty_flag#*:}; wasset=${rest%%:*}; val=${rest#*:}
  if [ "$wasset" = 1 ] && [ -z "$val" ]; then
    echo "REFUSED: $flag was given an empty value; name it or leave the flag out." >&2
    exit 1
  fi
done

META="$STATE/$ID.meta"
if [ -z "$PROJ" ] || [ -z "$PR" ]; then
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META (pass --project and the PR explicitly to merge without one)" >&2; exit 1; }
  # tail -1 on every field, not just pr=: a duplicated key would otherwise yield
  # a MULTI-LINE value, and a multi-line $MODE silently fails the local-only
  # comparison below instead of matching it.
  [ -n "$PROJ" ] || PROJ=$(grep '^project=' "$META" | cut -d= -f2- | tail -1 || true)
  [ -n "$PR" ] || PR=$(grep '^pr=' "$META" | cut -d= -f2- | tail -1 || true)
fi
[ -n "$PROJ" ] || { echo "error: task $ID has no project= in $META and no --project was given" >&2; exit 1; }

# Checked BEFORE the missing-PR error: a local-only task can never have a PR, so
# "pass the PR url or number" would be advice the caller cannot act on. Both
# paths refuse, but only one of them says where to go instead.
if [ -f "$META" ]; then
  MODE=$(grep '^mode=' "$META" | cut -d= -f2- | tail -1 || true)
  if [ "$MODE" = local-only ]; then
    echo "error: task $ID is mode=local-only and has no PR; merge it with bin/fm-merge-local.sh" >&2
    exit 1
  fi
fi

[ -n "$PR" ] || { echo "error: task $ID has no pr= in $META; pass the PR url or number" >&2; exit 1; }

# The PR reference is validated HERE, before any remote is inspected: a ref this
# tool cannot read a pull request out of is unusable no matter which repository
# it would have resolved to, and saying so plainly beats failing later with a
# target already announced.
NUM=$(fm_merge_target_pr_number "$PR") || {
  echo "REFUSED: '$PR' is not a pull request this tool can name." >&2
  echo "         Give a bare number, or a full https://github.com/<owner>/<repo>/pull/<n> url." >&2
  exit 1
}

# --- resolve the target, or refuse ------------------------------------------
set +e
RESOLVED=$(fm_merge_target "$PROJ" "$PR" "$WANT_REPO" "$WANT_REMOTE")
rc=$?
set -e
VERDICT=$(printf '%s\n' "$RESOLVED" | head -1 | cut -f1)

if [ "$rc" -ne 0 ]; then
  case "$VERDICT" in
    AMBIGUOUS)
      {
        printf '●%s\n' "$RULE"
        printf '●  MERGE TARGET AMBIGUOUS - REFUSING TO GUESS\n'
        printf '●  %s has more than one remote, and nothing named which\n' "$PROJ"
        printf '●  repository PR "%s" belongs to. It exists independently in each:\n' "$PR"
        printf '%s\n' "$RESOLVED" | tail -n +2 | while IFS=$'\t' read -r rname rslug; do
          printf '●      %-12s %s\n' "$rname" "$rslug"
        done
        printf '●  A merge is not reversible from here, so say which one:\n'
        printf '●      bin/fm-merge-pr.sh %s %s --remote <name-above>\n' "$ID" "$PR"
        printf '●      bin/fm-merge-pr.sh %s https://github.com/<owner>/<repo>/pull/<n>\n' "$ID"
        printf '●%s\n' "$RULE"
      } >&2 ;;
    NOREMOTE)
      echo "REFUSED: $PROJ has no remotes, so there is no repository to merge $PR in." >&2 ;;
    BADREPO)
      printf 'REFUSED: --repo %s is not a valid owner/name.\n' "$(printf '%s\n' "$RESOLVED" | head -1 | cut -f2)" >&2 ;;
    BADREMOTE)
      printf 'REFUSED: remote "%s" is not a usable GitHub repository (%s).\n' \
        "$(printf '%s\n' "$RESOLVED" | head -1 | cut -f2)" \
        "$(printf '%s\n' "$RESOLVED" | head -1 | cut -f3)" >&2 ;;
    NOTAGIT)
      echo "REFUSED: $PROJ is not a git work tree; cannot resolve a merge target." >&2 ;;
    *)
      echo "REFUSED: cannot resolve a merge target for $PROJ ($VERDICT)." >&2 ;;
  esac
  exit 1
fi

TARGET=$(printf '%s\n' "$RESOLVED" | head -1 | cut -f2)
SOURCE=$(printf '%s\n' "$RESOLVED" | head -1 | cut -f3)

# A url naming a DIFFERENT repository than the resolved target is two statements
# about one merge that disagree. Only the number survives a url once --repo or
# --remote has won precedence, so without this the caller's own PR reference
# silently becomes a number applied to somebody else's repository.
if CONFLICT=$(fm_merge_target_pr_slug_conflict "$TARGET" "$PR"); then
  {
    printf '●%s\n' "$RULE"
    printf '●  MERGE REFERENCE CONFLICTS WITH THE MERGE TARGET - REFUSING\n'
    printf '●  The pull request url names   %s\n' "$CONFLICT"
    printf '●  The resolved target is       %s   (from %s)\n' "$TARGET" "$SOURCE"
    printf '●  PR %s in %s is not PR %s in %s,\n' "$NUM" "$CONFLICT" "$NUM" "$TARGET"
    printf '●  and nothing here says which one you meant. Give the url for the\n'
    printf '●  repository you are merging in, or a bare number with the target:\n'
    printf '●      bin/fm-merge-pr.sh %s https://github.com/%s/pull/%s\n' "$ID" "$TARGET" "$NUM"
    printf '●      bin/fm-merge-pr.sh %s %s --repo %s\n' "$ID" "$NUM" "$TARGET"
    printf '●%s\n' "$RULE"
  } >&2
  exit 1
fi

# Informational only, and deliberately loud: merging into anything that is not
# this clone's origin is legitimate (an upstream contribution) but it is also
# the shape of the 2026-08-29 near-miss, so it is never silent.
ORIGIN_SLUG=$(fm_merge_target_from_url "$(git -C "$PROJ" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)
if [ -n "$ORIGIN_SLUG" ] && [ "$ORIGIN_SLUG" != "$TARGET" ]; then
  WHICH=$(fm_merge_target_remote_for "$PROJ" "$TARGET" || true)
  printf 'NOTE: %s is NOT this clone'"'"'s origin (%s)%s. Merging there anyway because it was named.\n' \
    "$TARGET" "$ORIGIN_SLUG" "${WHICH:+ - it is remote \"$WHICH\"}" >&2
fi

printf 'merge target: %s (from %s) - PR %s\n' "$TARGET" "$SOURCE" "$NUM" >&2

if [ "$DRYRUN" = 1 ]; then
  printf 'gh-axi pr merge %s --repo %s' "$NUM" "$TARGET"
  for arg in ${EXTRA[@]+"${EXTRA[@]}"}; do
    printf ' %s' "$(fm_merge_target_shquote "$arg")"
  done
  printf '\n'
  exit 0
fi

exec gh-axi pr merge "$NUM" --repo "$TARGET" ${EXTRA[@]+"${EXTRA[@]}"}
