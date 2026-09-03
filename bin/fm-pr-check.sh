#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> to state/<id>.meta and arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff
# the PR is merged (the watcher's check contract: output = wake firstmate,
# silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
#
# THE POLL SCRIPT IS COMPILED, AND ITS INPUT IS CREWMATE-SUPPLIED. AGENTS.md
# section 7 has the crewmate report `done: PR <url>` and has firstmate paste
# that value in here. That string used to be expanded at write time straight
# into a double-quoted word of the generated file:
#
#     state=$(gh pr view "<url>" --json state -q .state 2>/dev/null)
#
# bin/fm-watch.sh runs that file as `timeout N bash <file>` every
# FM_CHECK_INTERVAL, for as long as the task is armed - so a `"` in the url
# closed the word and everything after it became shell the WATCHER executed, on
# a timer, indefinitely, inside the session that holds the helm and merge
# authority. `~/.claude/settings.json` deny rules do not reach it: the payload
# runs inside a script the watcher invokes, never as a top-level tool call.
#
# Two things stop it now, and they are deliberately independent:
#
#   THE GATE.     The reference is parsed by fm_merge_target_parse_pr_ref, this
#                 repo's own single-walk PR-reference parser - the same rule
#                 bin/fm-merge-pr.sh proves a merge target with. It does not
#                 parse, nothing happens: no check.sh, no pr= line, no side
#                 effect of any kind.
#   THE SEATBELT. The poll script is emitted from the PARSED COMPONENTS - a
#                 validated owner/name slug and a digit-only number - rather
#                 than from the argument. Not every accepted reference is inert:
#                 a query naming no second pull request parses fine and may
#                 still carry a quote (`.../pull/1?x=";touch ./EVIL;"`), so the
#                 validator alone is not the whole answer. Emitting from
#                 components means no caller byte reaches the generated shell
#                 even if the parser is later loosened.
#
# Gate: gate-t5-prcheck-ref-not-compiled.
# Spec: docs/specs/2026-09-02-prcheck-ref-injection.md
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
# when the holder is provably dead.
# Spec: docs/specs/2026-08-27-n-concurrent-firstmates.md, section 4.
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
fm_lock_require_helm "$STATE" fm-pr-check || exit 1
ID=$1
URL=$2

# THE GATE. Ahead of the Quarterdeck and ahead of every side effect, because an
# argument that is not a pull-request reference is the cheapest question here
# and the only one whose wrong answer becomes executable shell. The refusal
# names the rail that produced it - a generic "invalid" costs another cycle to
# diagnose, which is half of what a named rail saves.
# shellcheck source=bin/fm-merge-target-lib.sh
. "$SCRIPT_DIR/fm-merge-target-lib.sh"
if ! PR_PARSED=$(fm_merge_target_parse_pr_ref "$URL"); then
  {
    printf 'REFUSED[pr-ref/%s]: not a pull-request reference: %s\n' \
      "${PR_PARSED#ERR	}" "$URL"
    printf '         A PR reference is exactly https://github.com/<owner>/<repo>/pull/<n>,\n'
    printf '         with an optional query or fragment naming no second pull request.\n'
    printf '         Nothing was armed and no pr= was recorded. Paste the plain PR link.\n'
  } >&2
  exit 1
fi
PR_PARSED=${PR_PARSED#OK	}
PR_SLUG=${PR_PARSED%%	*}
PR_NUM=${PR_PARSED##*	}

# Quarterdeck: arming the merge poll implies the work is accepted — gated on an
# independent verifier approve exactly like fm-merge-local. Spec:
# docs/specs/2026-07-01-agent-os-council.md. FM_VERIFY_OVERRIDE=1 bypasses loudly.
# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
fm_verdict_require_approve "$STATE" "$ID" fm-pr-check

META="$STATE/$ID.meta"
if [ -f "$META" ] && ! grep -qxF "pr=$URL" "$META"; then
  echo "pr=$URL" >> "$META"
fi

# THE SEATBELT. Written from the two parsed components and nothing else. Both
# came out of the parse above: PR_NUM is digits, and PR_SLUG passed
# fm_merge_target_valid_slug, whose character class is [A-Za-z0-9._/-] - neither
# can contain a quote, so the single quotes here cannot be closed from the
# outside the way the old double-quoted url could. Pinning --repo also means the
# poll names the repository it asks about rather than leaving `gh` to infer one
# from whatever clone the watcher happens to be standing in.
# shellcheck disable=SC2016  # the single quotes are the point: this format string
# is a LITERAL, so nothing expands at write time except the two %s components.
printf 'state=$(gh pr view %s --repo %s --json state -q .state 2>/dev/null)\n[ "$state" = "MERGED" ] && echo "merged"\n' \
  "'$PR_NUM'" "'$PR_SLUG'" > "$STATE/$ID.check.sh"
echo "armed: state/$ID.check.sh polls $URL"
