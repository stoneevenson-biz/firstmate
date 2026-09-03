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
#     --allow-non-origin    affirm a merge into a repository that is NOT this
#                           clone's origin (an upstream contribution)
#     --dry-run             print the exact merge command and exit, running none
#
# EVERY WAY THE TARGET CAN BE INFLUENCED, AND WHERE EACH IS CLOSED. The question
# is not "is this reference valid?" - three rounds of patching asked that one and
# a fourth hole arrived each time. The question is: can ANY input, in ANY
# position, cause a merge against a repository other than the one resolved from
# this clone's origin? Each answer below is a separately named refusal, so no
# single regex or refactor can quietly reopen one.
#
#   the PR reference   fm_merge_target_parse_pr_ref - one parse, both answers,
#                      and its own reason per rail: foreign-host, a second
#                      /pull/ in the query, a second /pull/ in the fragment,
#                      trailing path segments.
#   argument           an ALLOWLIST after `--`, not a blocklist. Short flags are
#   passthrough        refused wholesale (they cluster, and they carry attached
#                      values: `-Rowner/repo` and `-dR owner/repo` are how the
#                      blocklist was beaten); long options must be in a fixed
#                      sanctioned set.
#   repeated flags     `--repo`/`--remote`/`--project` given twice, or a `--repo`
#                      and a `--remote` that disagree, are two statements about
#                      one merge. Both refuse; neither is silently resolved by
#                      precedence, because `gh` resolving by "last one wins" is
#                      the whole reason this script exists.
#   environment        `GH_REPO` and `GH_HOST` redirect a gh-shaped tool without
#                      touching its argv - same slug, different server - and
#                      `GIT_DIR` overrides `git -C <dir>` outright, which would
#                      redirect the resolution AND the origin proof that checks
#                      it, to the same wrong clone. The exec PINS the first two;
#                      fm_merge_target_git scrubs the third on every remote read.
#   the git config     the GIT_CONFIG family substitutes git's CONFIGURATION
#                      rather than its repository, and a remote URL is
#                      configuration: `url.<attacker>.insteadOf` rewrites what
#                      `remote get-url` answers, so both the resolution and the
#                      origin proof read the substituted value and agree. The
#                      whole family is swept by PREFIX (its indices are
#                      unbounded, so no list can cover it) and the global and
#                      system config files - which HOME and XDG_CONFIG_HOME
#                      choose - are pinned away with it. Unlike the row above,
#                      this one also REFUSES: nothing sets GIT_CONFIG_COUNT by
#                      accident.
#   the origin proof   the resolved owner/name must equal this clone's `origin`.
#                      A target that cannot be proven equal to origin REFUSES;
#                      leaving origin needs a second, explicit `--allow-non-origin`
#                      that no reference, remote or environment variable can supply.
#   the egress check   the finished argv is re-read before exec and must carry
#                      exactly one `--repo`, equal to the resolved target, and no
#                      other repository-naming argument in any spelling.
#
# Anything after `--` is passed through to `gh-axi pr merge` (e.g. --squash,
# --delete-branch) only if it is on that allowlist; an option gh grows that is
# not listed refuses, with a message saying to add it. A stale list costs one
# refusal; a permissive one costs a merge.
#
# Merge authority is unchanged: AGENTS.md still requires the captain's word (or
# an authorized `yolo` posture). This script decides WHERE a merge lands, never
# WHETHER it may happen.
#
# Spec: docs/specs/2026-08-31-merge-target-pin.md,
#       docs/specs/2026-09-02-merge-target-git-config.md
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# THE HELM. A second session on this home reads, reasons and drafts freely; it
# may not DRIVE. This is the writer-only seam - refused at the verb, at the
# moment it is asked for, never at boot. Deliberately not bin/fm-guard.sh, which
# always exits 0 by design. Escape hatch: bin/fm-lock.sh --take, permitted only
# when the holder is provably dead. Merging a PR is the verb section 4 names
# most directly, and this is the fleet's only path to it.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
fm_lock_require_helm "$STATE" fm-merge-pr || exit 1

# shellcheck source=bin/fm-merge-target-lib.sh
. "$SCRIPT_DIR/fm-merge-target-lib.sh"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
usage() {
  echo "usage: fm-merge-pr.sh <task-id> [<pr-url-or-number>] [--repo <owner/name>] [--remote <name>] [--project <dir>] [--allow-non-origin] [--dry-run] [-- <gh-axi args>]" >&2
  exit 2
}

ID=""; PR=""; WANT_REPO=""; WANT_REMOTE=""; PROJ=""; DRYRUN=0; ALLOW_NON_ORIGIN=0
WANT_REPO_SET=0; WANT_REMOTE_SET=0; PROJ_SET=0
EXTRA=()

# A refusal names the rail that produced it. `REFUSED[<rail>]` is the contract a
# gate asserts on: a generic refusal proves only that SOMETHING stopped, which is
# exactly what let three patched holes each be replaced by the next one.
refuse() {
  printf 'REFUSED[%s]: %s\n' "$1" "$2" >&2
  shift 2
  for line in "$@"; do printf '         %s\n' "$line" >&2; done
  exit 1
}

# --- the environment, before anything else ----------------------------------
#
# `git remote get-url origin` is not a fact about a clone. It is a fact about a
# clone READ THROUGH a configuration, and the GIT_CONFIG family substitutes that
# configuration straight from the environment: `url.<attacker>.insteadOf`
# rewrites the URL as git hands it back, so the resolution below AND the origin
# proof that checks it would read the same substituted value and agree with each
# other perfectly. bin/fm-merge-target-lib.sh now neutralises that on every read,
# so the target resolved below is the honest one either way.
#
# This is the second half, and the fleet needs both. Something injecting git
# configuration into a merge path is hostile or badly broken, and "we read the
# right answer anyway" is not a reason to continue - it is a reason to stop and
# say what was found. So the check runs FIRST, ahead of argument parsing and
# ahead of the passthrough allowlist: nothing at all should run in an
# environment that is substituting git's view of this repository.
#
# DELIBERATELY NOT THE TREATMENT GH_REPO AND GIT_DIR GET, which are pinned and
# scrubbed but never refused on. Those are set by ordinary tooling for ordinary
# reasons - a git hook exports GIT_DIR to every command it runs - so refusing on
# them would refuse ordinary merges. `HOME` is on that same side of the line and
# is neutralised rather than refused, because every environment has one. Nothing
# sets GIT_CONFIG_COUNT by accident: its only purpose is to substitute
# configuration, so its presence here IS the finding.
#
# Spec: docs/specs/2026-09-02-merge-target-git-config.md
GIT_CONFIG_ENV=$(fm_merge_target_git_config_env)
if [ -n "$GIT_CONFIG_ENV" ]; then
  {
    printf '\u25cf%s\n' "$RULE"
    printf '\u25cf  GIT CONFIGURATION IS BEING SUBSTITUTED FROM THE ENVIRONMENT - REFUSING\n'
    printf '\u25cf  REFUSED[env/git-config-injected]\n'
    printf '\u25cf  These variables are set, and they replace what git believes about\n'
    printf '\u25cf  this repository - including what "remote get-url" answers:\n'
    printf '%s\n' "$GIT_CONFIG_ENV" | while IFS= read -r v; do
      [ -n "$v" ] && printf '\u25cf      %s\n' "$v"
    done
    printf '\u25cf  A url.<other>.insteadOf here rewrites the remote URL as git hands it\n'
    printf '\u25cf  back, so the resolved target AND the origin proof that checks it read\n'
    printf '\u25cf  the same substituted value and agree. Every read on this path ignores\n'
    printf '\u25cf  them, so nothing was merged anywhere - but an environment that does\n'
    printf '\u25cf  this to a merge is hostile or broken, and passing quietly is not the\n'
    printf '\u25cf  same as handling it.\n'
    printf '\u25cf  Unset them and run the merge again.\n'
    printf '\u25cf%s\n' "$RULE"
  } >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; WANT_REPO=$2; WANT_REPO_SET=$((WANT_REPO_SET + 1)); shift 2 ;;
    --repo=*) WANT_REPO=${1#--repo=}; WANT_REPO_SET=$((WANT_REPO_SET + 1)); shift ;;
    --remote) [ $# -ge 2 ] || usage; WANT_REMOTE=$2; WANT_REMOTE_SET=$((WANT_REMOTE_SET + 1)); shift 2 ;;
    --remote=*) WANT_REMOTE=${1#--remote=}; WANT_REMOTE_SET=$((WANT_REMOTE_SET + 1)); shift ;;
    --project) [ $# -ge 2 ] || usage; PROJ=$2; PROJ_SET=$((PROJ_SET + 1)); shift 2 ;;
    --project=*) PROJ=${1#--project=}; PROJ_SET=$((PROJ_SET + 1)); shift ;;
    --allow-non-origin) ALLOW_NON_ORIGIN=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --)
      shift
      while [ $# -gt 0 ]; do EXTRA+=("$1"); shift; done ;;
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

# ONE STATEMENT PER TARGET. `--repo a --repo b` is not "b wins"; it is two
# statements about one merge, and picking the last one is precisely the gh
# behaviour this script was written to stop relying on. Repetition refuses even
# when the two values agree, because "they happened to agree this time" is not a
# property anybody checked.
for dup in "--repo:$WANT_REPO_SET" "--remote:$WANT_REMOTE_SET" "--project:$PROJ_SET"; do
  if [ "${dup#*:}" -gt 1 ]; then
    refuse target/duplicate-flag "${dup%%:*} was given ${dup#*:} times; a merge target is named once." \
      "Two occurrences are two statements about one merge, and this script does not pick a winner."
  fi
done

# An EMPTY flag value is not a choice, and must never be read as "no flag given"
# - that would silently hand the decision back to the remote set the caller was
# in the middle of overriding. `--repo=` is a typo, not consent.
for empty_flag in "--repo:$WANT_REPO_SET:$WANT_REPO" "--remote:$WANT_REMOTE_SET:$WANT_REMOTE" "--project:$PROJ_SET:$PROJ"; do
  flag=${empty_flag%%:*}; rest=${empty_flag#*:}; wasset=${rest%%:*}; val=${rest#*:}
  if [ "$wasset" -ge 1 ] && [ -z "$val" ]; then
    refuse target/empty-flag "$flag was given an empty value; name it or leave the flag out."
  fi
done

# Passthrough is validated BEFORE anything else runs: an argv this script would
# refuse to execute must not first resolve a target, print it, and only then
# stop - a printed target that never merged reads like a merge that happened.
PASS=$(fm_merge_target_check_passthrough ${EXTRA[@]+"${EXTRA[@]}"}) || {
  PASS_REASON=$(printf '%s\n' "$PASS" | cut -f2)
  PASS_ARG=$(printf '%s\n' "$PASS" | cut -f3)
  case "$PASS_REASON" in
    repo-flag)
      refuse passthrough/repo-flag "'$PASS_ARG' after -- names a repository, which would override the pinned target." \
        "gh-axi keeps the LAST repo flag it sees, in any spelling - detached (-R x), inline (-R=x)," \
        "attached (-Rx) or clustered (-dRx) - so none of them may reach it." \
        "Name the repository with this script's own --repo/--remote, before the --." ;;
    repo-flag-as-value)
      refuse passthrough/repo-flag-as-value "'$PASS_ARG' would sit where a repository flag could be read." \
        "An option's value is data, but how many words an option takes is this tool's belief about" \
        "gh-axi rather than something it can check - so a value that could name a repository is" \
        "refused rather than trusted. Reword it, or name the repository before the --." ;;
    short-flag)
      refuse passthrough/short-flag "'$PASS_ARG' is a short flag; passthrough accepts long options only." \
        "A short flag can cluster and can carry its value attached, which is how a repository" \
        "flag hid inside one. Use the long form of the option instead." ;;
    unknown-flag)
      refuse passthrough/unknown-flag "'$PASS_ARG' is not a sanctioned merge option." \
        "Passthrough is an allowlist: $FM_MERGE_PASSTHROUGH_BARE$FM_MERGE_PASSTHROUGH_VALUED" \
        "If this option is genuinely wanted, add it to the set in bin/fm-merge-target-lib.sh." ;;
    positional)
      refuse passthrough/positional "'$PASS_ARG' after -- is a bare argument, not an option." \
        "The pull request is named before the --; a second positional would be a second subject." ;;
    value-on-bare-flag)
      refuse passthrough/value-on-bare-flag "'$PASS_ARG' takes no value." ;;
    empty-value)
      refuse passthrough/empty-value "'$PASS_ARG' was given an empty value." ;;
    missing-value)
      refuse passthrough/missing-value "'$PASS_ARG' needs a value and none followed it." ;;
    *)
      refuse passthrough/rejected "'$PASS_ARG' is not accepted after -- ($PASS_REASON)." ;;
  esac
}

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
# target already announced. The refusal names WHICH rail stopped it, because
# "not a pull request" is the message that let three different holes look alike.
if ! NUM=$(fm_merge_target_pr_number "$PR"); then
  RAIL=$(fm_merge_target_pr_ref_reason "$PR" || true)
  case "$RAIL" in
    foreign-host)
      refuse pr-ref/foreign-host "'$PR' is not an https://github.com/ pull-request url." \
        "Its scheme and host are matched exactly, never searched for: a reference on another" \
        "host names a pull request in another system, and lending its number to whichever" \
        "repository the remotes resolved is exactly the wrong-repo merge this path prevents." ;;
    second-pull-in-query)
      refuse pr-ref/second-pull-in-query "'$PR' names a second pull request in its QUERY string." \
        "A reference names exactly one pull request. Reading the repository from one /pull/ and" \
        "the number from another merged a pull request nobody asked for, while every cross-check" \
        "saw a repository agreeing with itself. Paste the url without the query." ;;
    second-pull-in-fragment)
      refuse pr-ref/second-pull-in-fragment "'$PR' names a second pull request in its FRAGMENT." \
        "A reference names exactly one pull request; a #fragment mentioning another makes it" \
        "ambiguous about its own subject. Paste the url without the fragment." ;;
    trailing-path)
      refuse pr-ref/trailing-path "'$PR' has path segments after the pull request number." \
        "A trailing /files or /commits is refused rather than trimmed: trimming is how a url" \
        "that says one thing came to mean another. Paste it up to the number." ;;
    non-numeric-number)
      refuse pr-ref/non-numeric-number "'$PR' does not end in a pull-request number." ;;
    bad-slug)
      refuse pr-ref/bad-slug "'$PR' does not name a valid owner/repository." ;;
    not-a-pull-path)
      refuse pr-ref/not-a-pull-path "'$PR' is a github.com url, but not a pull-request one." \
        "Expected https://github.com/<owner>/<repo>/pull/<n>." ;;
    *)
      refuse pr-ref/not-a-url "'$PR' is not a pull request this tool can name." \
        "Give a bare number, or a full https://github.com/<owner>/<repo>/pull/<n> url." ;;
  esac
fi

# --- resolve the target, or refuse ------------------------------------------
#
# `--repo` and `--remote` both given is the same defect as a repeated flag, one
# level up: two independent statements about one merge. The library's precedence
# rule would silently let --repo win, and "silently let one win" is what merged
# into upstream on 2026-08-29. So they must agree, and disagreement stops.
if [ "$WANT_REPO_SET" -ge 1 ] && [ "$WANT_REMOTE_SET" -ge 1 ]; then
  REMOTE_SLUG=$(fm_merge_target_from_url "$(fm_merge_target_git "$PROJ" remote get-url "$WANT_REMOTE" 2>/dev/null || true)" 2>/dev/null || true)
  if [ -z "$REMOTE_SLUG" ] || [ "$REMOTE_SLUG" != "$WANT_REPO" ]; then
    refuse target/conflicting-flags "--repo $WANT_REPO and --remote $WANT_REMOTE do not name the same repository." \
      "remote \"$WANT_REMOTE\" is ${REMOTE_SLUG:-not a usable GitHub repository}." \
      "Give one of them, not both; this script does not resolve the disagreement by precedence."
  fi
fi

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
        printf '●  REFUSED[target/ambiguous-remotes]\n'
        printf '●  %s has more than one remote, and nothing named which\n' "$PROJ"
        printf '●  repository PR "%s" belongs to. It exists independently in each:\n' "$PR"
        printf '%s\n' "$RESOLVED" | tail -n +2 | while IFS=$'\t' read -r rname rslug; do
          printf '●      %-12s %s\n' "$rname" "$rslug"
        done
        printf '●  A merge is not reversible from here, so say which one:\n'
        printf '●      bin/fm-merge-pr.sh %s %s --remote <name-above>\n' "$ID" "$PR"
        printf '●      bin/fm-merge-pr.sh %s https://github.com/<owner>/<repo>/pull/<n>\n' "$ID"
        printf '●%s\n' "$RULE"
      } >&2
      exit 1 ;;
    NOREMOTE)
      refuse target/no-remote "$PROJ has no remotes, so there is no repository to merge $PR in." ;;
    BADREPO)
      refuse target/bad-repo "--repo $(printf '%s\n' "$RESOLVED" | head -1 | cut -f2) is not a valid owner/name." ;;
    BADREMOTE)
      refuse target/bad-remote "remote \"$(printf '%s\n' "$RESOLVED" | head -1 | cut -f2)\" is not a usable GitHub repository ($(printf '%s\n' "$RESOLVED" | head -1 | cut -f3))." ;;
    NOTAGIT)
      refuse target/not-a-git-worktree "$PROJ is not a git work tree; cannot resolve a merge target." ;;
    *)
      refuse target/unresolved "cannot resolve a merge target for $PROJ ($VERDICT)." ;;
  esac
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
    printf '●  REFUSED[target/pr-url-conflict]\n'
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

# --- the origin proof --------------------------------------------------------
#
# Everything above establishes that the target was NAMED rather than inferred.
# This establishes what it was named as. A clone is OF a repository - its
# `origin` - and a merge that lands anywhere else is, by default, the shape of
# the 2026-08-29 near-miss: `gh-axi pr merge 5` in a clone with two remotes
# resolving to upstream.
#
# Being named is no longer enough on its own. A reference, a remote name, a slug
# and an environment variable are all things a caller can be handed by something
# else - a pasted url, a recorded meta line, an exported variable - so any of
# them arriving from elsewhere would otherwise be sufficient authority to leave
# origin. Leaving origin now needs a SECOND statement that nothing but a human at
# the command line can make: --allow-non-origin. It names no repository, so it
# cannot itself be the thing that redirects a merge; it only affirms that the
# repository already named is meant to be somewhere other than here.
#
# And origin that cannot be read at all is not a pass. It is the proof failing,
# which refuses, because "we could not check" and "we checked and it was fine"
# are the two answers a merge gate must never confuse.
ORIGIN_SLUG=$(fm_merge_target_origin_slug "$PROJ" 2>/dev/null || true)
if [ "$TARGET" != "$ORIGIN_SLUG" ]; then
  WHICH=$(fm_merge_target_remote_for "$PROJ" "$TARGET" || true)
  if [ "$ALLOW_NON_ORIGIN" != 1 ]; then
    RAIL=target/not-origin
    [ -n "$ORIGIN_SLUG" ] || RAIL=target/origin-unprovable
    {
      printf '●%s\n' "$RULE"
      printf '●  MERGE TARGET IS NOT THIS CLONE'"'"'S ORIGIN - REFUSING\n'
      printf '●  REFUSED[%s]\n' "$RAIL"
      printf '●  Resolved target   %s   (from %s)\n' "$TARGET" "$SOURCE"
      if [ -n "$ORIGIN_SLUG" ]; then
        printf '●  This clone'"'"'s origin  %s\n' "$ORIGIN_SLUG"
      else
        printf '●  This clone'"'"'s origin  COULD NOT BE READ - %s has no usable origin remote.\n' "$PROJ"
        printf '●  A proof that did not run is not a proof that passed.\n'
      fi
      printf '●  Merging outside origin is legitimate - an upstream contribution is\n'
      printf '●  exactly that - but it is also the shape of the 2026-08-29 near-miss,\n'
      printf '●  so it takes a second, deliberate word that no url, remote or\n'
      printf '●  environment variable can speak for you:\n'
      printf '●      bin/fm-merge-pr.sh %s %s --repo %s --allow-non-origin\n' "$ID" "$NUM" "$TARGET"
      printf '●%s\n' "$RULE"
    } >&2
    exit 1
  fi
  printf 'NOTE: %s is NOT this clone'"'"'s origin (%s)%s. Merging there because --allow-non-origin was given.\n' \
    "$TARGET" "${ORIGIN_SLUG:-unreadable}" "${WHICH:+ - it is remote \"$WHICH\"}" >&2
fi

printf 'merge target: %s (from %s) - PR %s\n' "$TARGET" "$SOURCE" "$NUM" >&2

# --- the egress check --------------------------------------------------------
#
# The argv is BUILT from validated components - a number proved to be digits, a
# target proved to be a slug, options drawn from a fixed allowlist - rather than
# assembled from anything the caller wrote. Then it is read back and proved to
# pin the target exactly once, because a construction that is correct today is
# not a construction that stays correct: a flag added to the wrong set, an
# argument appended by a future caller, a refactor of the allowlist. This check
# reads the finished command, so none of those can pass silently.
ARGV=(pr merge "$NUM" --repo "$TARGET" ${EXTRA[@]+"${EXTRA[@]}"})
EGRESS=$(fm_merge_target_assert_argv "$TARGET" "${ARGV[@]}") || {
  refuse "egress/$(printf '%s\n' "$EGRESS" | cut -f2)" \
    "the merge command does not pin the resolved target ($(printf '%s\n' "$EGRESS" | cut -f3))." \
    "This is an internal error in fm-merge-pr.sh, not a mistake in what you typed." \
    "Nothing was merged. Please report it with the command you ran."
}

# The ENVIRONMENT is pinned too, not merely inherited. `GH_REPO` names a default
# repository and `GH_HOST` names a default server, and a gh-shaped tool reads
# both without any of it appearing in the argv this script just proved - the same
# owner/name on a different host is a different repository. So both are SET here
# to agree with the resolved target rather than left to whatever the caller's
# shell happened to export. github.com is not a policy choice: it is the only
# host bin/fm-merge-target-lib.sh will resolve a repository from at all.
GH_ENV=(GH_HOST=github.com "GH_REPO=$TARGET")

if [ "$DRYRUN" = 1 ]; then
  printf 'env'
  for e in "${GH_ENV[@]}"; do printf ' %s' "$(fm_merge_target_shquote "$e")"; done
  printf ' gh-axi'
  for arg in "${ARGV[@]}"; do printf ' %s' "$(fm_merge_target_shquote "$arg")"; done
  printf '\n'
  exit 0
fi

exec env "${GH_ENV[@]}" gh-axi "${ARGV[@]}"
