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
#   THE SEATBELT. The poll script is emitted from the PARSED COMPONENTS, each
#                 serialised with `printf %q`, rather than from the argument.
#                 Not every accepted reference is inert: a query naming no
#                 second pull request parses fine and may still carry a quote
#                 (`.../pull/1?x=";touch ./EVIL;"`), so the validator alone is
#                 not the whole answer.
#
#                 WHAT THIS DOES AND DOES NOT SURVIVE. `%q` is what makes the
#                 shell layer independent of the parse: whatever a component
#                 contains - a quote, a semicolon, a newline - it lands in the
#                 generated file as exactly one word, so no caller byte can
#                 become shell even if the parser is later loosened. Wrapping
#                 the components in literal quotes would NOT have done that; it
#                 would only have moved the dependency from "the parser rejects
#                 `\"`" to "the parser rejects `'`", which is not independence.
#                 What the gate still owns is the components' MEANING - that the
#                 slug is a repository rather than, say, an attached `-Rowner/x`
#                 that `gh` itself would read as a flag. Independent at the
#                 shell layer; never a substitute for the parse.
#
#   THE LINE RULE. `pr=<url>` goes into a LINE-ORIENTED file that every reader
#                 parses with `grep '^key=' | tail -1`, so a newline in the
#                 reference is a forged meta record - a `worktree=` or
#                 `harness=` line that WINS over the real one, because it comes
#                 last. The parser cannot answer this: it strips the query and
#                 fragment before validating anything, so a control character
#                 living in either parses perfectly well. Encoding for a
#                 line-oriented file is this script's own concern, so the rail
#                 is here rather than in the shared parser.
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
# A control character never appears in a legal url, and a newline in one is a
# forged record in state/<id>.meta - see THE LINE RULE above. Asked before the
# parse, because the parse strips the query and fragment without validating
# either. LC_ALL=C is already in force: bin/fm-merge-target-lib.sh sets it so
# every bracket range in this path is asked in one collation.
case "$URL" in
  *[[:cntrl:]]*)
    {
      printf 'REFUSED[pr-ref/control-character]: a PR reference may not contain a control character.\n'
      printf '         A newline here would become a forged record in the task meta, which readers\n'
      printf "         take the LAST of. Nothing was armed and no pr= was recorded.\n"
    } >&2
    exit 1 ;;
esac

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

# THE SEATBELT. Written from the two parsed components and nothing else, each
# serialised by `printf %q` - bash's own "quote this so it re-reads as exactly
# this one word". That is the whole independence claim and its whole limit: no
# component can become shell whatever it contains, while what it MEANS to gh is
# still the parser's guarantee (see the header). Pinning --repo also means the
# poll names the repository it asks about rather than leaving `gh` to infer one
# from whatever clone the watcher happens to be standing in.
# shellcheck disable=SC2016  # the single quotes are the point: this format string
# is a LITERAL, so nothing expands at write time except the two %s components.
printf 'state=$(gh pr view %s --repo %s --json state -q .state 2>/dev/null)\n[ "$state" = "MERGED" ] && echo "merged"\n' \
  "$(printf '%q' "$PR_NUM")" "$(printf '%q' "$PR_SLUG")" > "$STATE/$ID.check.sh"
echo "armed: state/$ID.check.sh polls $URL"
