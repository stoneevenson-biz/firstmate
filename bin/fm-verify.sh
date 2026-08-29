#!/usr/bin/env bash
# Quarterdeck: the structural verifier stage between a crewmate's `done:` claim
# and firstmate's acceptance. Spec: docs/specs/2026-07-01-agent-os-council.md.
#
# `done:` is a claim, not an acceptance. fm-verify.sh, run by firstmate when a
# ship task reports done:
#   1. adjudicates the worktree's gate ledger STRUCTURALLY, before either model
#      runs (fm_gates_classify in fm-gates-lib.sh) - see "gate adjudication"
#   2. snapshots the crewmate's diff        -> data/<id>/lens-diff.patch
#   3. runs the foreign lens on it          -> data/<id>/lens-review.md
#      (chain: FM_LENS_CMD > Fugu > codex > none - degrades loudly, never silently)
#   4. spawns an independent fresh-context verifier (default-REJECT) in the
#      crewmate's worktree                  -> data/<id>/verify-report.md
#   5. appends the decision to state/<id>.verdict (fm-verdict-lib grammar);
#      fm-merge-local/fm-pr-check refuse without a trailing approve.
#   6. on reject: relays findings to the crewmate (FM_RELAY_CMD, default
#      fm-send.sh); after FM_VERIFY_MAX_ATTEMPTS (default 3) rejects, escalates.
#
# GATE ADJUDICATION IS NOT THE MODEL'S JOB. It used to be: the verifier prompt
# said "every gate must be green; red or unproven gates are an automatic
# reject", which is unsatisfiable in any repo holding a declared red - and this
# one holds two. Whether correct work was accepted then depended on whether the
# LLM happened to reason about gates/accepted-red.md on that run. The rule now
# has one implementation, fm_gates_classify, and it runs in front of the lens
# and the verifier so an unacceptable ledger costs neither model. The prompt no
# longer states a gate rule at all; a second authority over one decision is what
# produced the contradiction.
#
# Fail closed: verifier won't run / emits no VERDICT line -> escalate, never
# approve. Non-ship tasks (scout/secondmate) skip in Phase 1.
#
# Seams: FM_VERIFY_CMD  verifier command; gets the prompt as $1, cwd=worktree,
#                       stdout must end with "VERDICT: approve|reject|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command; diff on stdin, review on stdout
#        FM_RELAY_CMD   reject relay; default bin/fm-send.sh (word-split)
# Exit: 0 approve or skip, 2 reject, 3 escalate, 1 usage error.
# Usage: fm-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
# shellcheck source=bin/fm-lens-lib.sh
. "$SCRIPT_DIR/fm-lens-lib.sh"
# shellcheck source=bin/fm-gates-lib.sh
. "$SCRIPT_DIR/fm-gates-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=${1:?usage: fm-verify.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "${KIND:-ship}" != ship ]; then
  echo "skip: task $ID kind=${KIND:-?} (Quarterdeck verifies ship tasks only in Phase 1)"
  exit 0
fi

WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -d "$WORKTREE" ] || { echo "error: worktree $WORKTREE missing for task $ID" >&2; exit 1; }
BRIEF="$DATA/$ID/brief.md"
mkdir -p "$DATA/$ID"

MAX=${FM_VERIFY_MAX_ATTEMPTS:-3}

# Already at the cap before this run? Straight to the captain, no more spins.
if [ "$(fm_verdict_reject_count "$STATE" "$ID")" -ge "$MAX" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($MAX rejects); captain decision required"
  echo "escalate: task $ID at attempt cap ($MAX rejects)" >&2
  exit 3
fi

# --- shared reject path -------------------------------------------------------
#
# The structural gate stage and the verifier both reject through here, so the
# attempt count, the verdict line, the relay, and the cap behave identically
# whichever stage found the problem. Two reject paths would drift.
verify_reject() {  # <reason> <findings-pointer>
  local reason=$1 findings=$2 n
  n=$(( $(fm_verdict_reject_count "$STATE" "$ID") + 1 ))
  fm_verdict_append "$STATE" "$ID" reject "(attempt $n of $MAX) $reason"
  # shellcheck disable=SC2086 # FM_RELAY_CMD is deliberately word-split
  ${FM_RELAY_CMD:-"$SCRIPT_DIR/fm-send.sh"} "fm-$ID" \
    "QUARTERDECK REJECTED (attempt $n of $MAX): $reason. Findings: $findings. Fix and append a fresh done: line." \
    || echo "warning: could not relay reject to fm-$ID (window gone?)" >&2
  if [ "$n" -ge "$MAX" ]; then
    fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($n rejects); captain decision required"
    echo "escalate: task $ID hit the attempt cap ($n of $MAX)" >&2
    exit 3
  fi
  echo "reject: task $ID (attempt $n of $MAX); findings relayed" >&2
  exit 2
}

verify_escalate() {  # <reason>
  fm_verdict_append "$STATE" "$ID" escalate "$1"
  echo "escalate: task $ID - $1" >&2
  exit 3
}

# --- 1. gate ledger adjudication (structural, ahead of both models) -----------
#
# Which way each condition fails, and why:
#
#   no gates/ dir            NOT APPLICABLE - proceed. Most projects firstmate
#                            ships to have no gate ledger at all; escalating on
#                            a missing file would stop every one of them.
#   red, declared with a
#     reason in accepted-red PROCEED. That is the whole point of the baseline.
#   red, undeclared          REJECT. Crewmate-actionable: make the gate green,
#                            or get its red declared. The kind of finding a
#                            fresh `done:` can answer.
#   gates/ but no
#     accepted-red.md        No declarations exist, so every red is undeclared
#                            by construction and rejects on the line above. A
#                            fully green ledger with no accepted-red.md is fine.
#   test_ref names a file
#     that is not on disk    REJECT. A ledger claiming green for a gate whose
#                            test no longer exists is stale by construction.
#                            This proves only that the ledger is not pointing at
#                            deleted tests - NOT that any test passes. Proving
#                            that is CI's job, and re-running the suite here
#                            would duplicate it at the most expensive moment.
#   gates/ but no ledger     ESCALATE. The repo declares itself gate-governed
#                            and the record of what is proven is gone; nothing
#                            can be proven either way. Infrastructure, not work.
#   unreadable ledger        ESCALATE. Same reason: a parse failure is not a
#                            finding a crewmate can fix by editing code.
#   unrecognised status      ESCALATE. Never a pass, and not a work defect - a
#                            ledger this repo cannot interpret needs a human.
#
# gates/verify.sh is deliberately never invoked: `ledger verify` re-runs every
# gate, REWRITES the ledger inside the crewmate's worktree, and is absent in CI.
GATE_RAW=$(fm_gates_classify "$WORKTREE")
GATE_HEADER=$(printf '%s\n' "$GATE_RAW" | head -1)
GATE_ROWS=$(printf '%s\n' "$GATE_RAW" | tail -n +2)

case "$GATE_HEADER" in
  NOGATES)
    echo "gates: no gates/ dir in $WORKTREE - gate adjudication not applicable"
    ;;
  NOLEDGER)
    verify_escalate "gates/ exists in $WORKTREE but gates/ledger.json does not - nothing can be proven about this repo's gates; fail closed"
    ;;
  BADLEDGER)
    verify_escalate "gates/ledger.json in $WORKTREE is unreadable or the wrong shape - gate state cannot be classified; fail closed"
    ;;
esac

if [ "$GATE_HEADER" != NOGATES ]; then
  # Unrecognised statuses first: they mean the ledger says something this repo
  # has no rule for, which no crewmate edit can resolve.
  GATE_UNKNOWN=$(printf '%s\n' "$GATE_ROWS" \
    | awk -F'\t' '$1 == "bad-status" { printf "%s (%s) ", $2, $3 }')
  [ -z "$GATE_UNKNOWN" ] \
    || verify_escalate "gate ledger holds a status this repo has no rule for: ${GATE_UNKNOWN% } - acceptable is green, or red and declared in gates/accepted-red.md; fail closed"

  GATE_UNDECLARED=$(printf '%s\n' "$GATE_ROWS" \
    | awk -F'\t' '$1 == "bad-red" { printf "%s ", $2 }')

  # Freshness cross-check: every gate must still point at a test that exists.
  GATE_STALE=""
  while IFS="$(printf '\t')" read -r _v gid _st tref _detail; do
    [ -n "${tref:-}" ] || continue
    [ -e "$WORKTREE/$tref" ] || GATE_STALE="$GATE_STALE$gid -> $tref; "
  done <<GATEROWS
$GATE_ROWS
GATEROWS

  if [ -n "$GATE_UNDECLARED" ]; then
    note=""
    [ "$GATE_HEADER" = NOACCEPTED ] \
      && note=" (this repo has no gates/accepted-red.md, so no red is declared)"
    verify_reject \
      "the gate ledger is red on ${GATE_UNDECLARED% } and that red is not declared in gates/accepted-red.md$note" \
      "gates/ledger.json and gates/accepted-red.md in your worktree; run bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE"
  fi

  if [ -n "$GATE_STALE" ]; then
    verify_reject \
      "the gate ledger references test files that do not exist on disk: ${GATE_STALE%; } - a ledger citing deleted tests is stale by construction" \
      "gates/ledger.json in your worktree; run bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE"
  fi

  echo "gates: acceptable (every gate green, frozen, or a declared red)"
fi

# --- 2. diff payload ---------------------------------------------------------
default_branch() {
  local ref branch
  ref=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"; return 0
    fi
  done
  return 1
}

DIFF_FILE="$DATA/$ID/lens-diff.patch"
{
  DEFAULT=$(default_branch || true)
  if [ -n "${DEFAULT:-}" ] && base=$(git -C "$WORKTREE" merge-base HEAD "$DEFAULT" 2>/dev/null); then
    git -C "$WORKTREE" log --oneline "$base..HEAD"
    git -C "$WORKTREE" diff "$base..HEAD"
  else
    echo "(no default branch resolvable; showing HEAD commit only)"
    git -C "$WORKTREE" show HEAD
  fi
} | head -c 200000 > "$DIFF_FILE"

# --- 3. foreign lens: shared chain (fm-lens-lib.sh) ----------------------------
LENS_REVIEW="$DATA/$ID/lens-review.md"
LENS_PROMPT="You are a hostile senior reviewer. Roast this diff before it ships: correctness bugs, untested claims, security holes, scope drift. Be specific (file:line). End with the findings that most deserve a reject, or 'no blocking findings'."

LENS=$(fm_lens_run "$DIFF_FILE" "$LENS_REVIEW" "$LENS_PROMPT" fugu "$WORKTREE" "task $ID")
fm_verdict_append "$STATE" "$ID" lens "$LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 4. independent verifier (fail closed) -------------------------------------
REPORT="$DATA/$ID/verify-report.md"
VERIFY_CMD=${FM_VERIFY_CMD:-claude -p --permission-mode bypassPermissions}

BRIEF_TEXT="(no brief found at $BRIEF)"
[ -f "$BRIEF" ] && BRIEF_TEXT=$(cat "$BRIEF")
# NO APOSTROPHES IN THIS HEREDOC BODY. It is an unquoted heredoc inside a
# command substitution, and bash re-scans that body when the substitution runs:
# a lone ' opens a quote it never closes, and the script dies at runtime with
# "unexpected EOF while looking for matching '" pointing at a line well past the
# heredoc. `bash -n` does NOT catch it. Verified: adding the single word
# "repo's" here made fm-verify exit 2 mid-run. Write "the ledger in this repo",
# never "this repo's ledger". The heredoc must stay unquoted so $BRIEF_TEXT,
# $LENS and $(cat "$LENS_REVIEW") still expand.
PROMPT=$(cat <<EOF
You are the Quarterdeck verifier: a fresh-context independent checker. The
crewmate for task $ID claims done. Default stance: REJECT until proven.
Never trust what the crewmate says - re-run everything yourself from this
worktree ($WORKTREE, branch fm/$ID).

Checklist:
1. Re-prove each claim in the definition of done below by EXECUTING it (run the
   tests, run the command, read the diff), not by trusting the report the crewmate wrote.
2. Weigh the foreign-lens review below; confirm or dismiss each finding.
3. No cheating: confirm tests were not weakened, skipped, or deleted, and the
   diff stays inside the assigned scope.

Out of scope for you: whether the gate ledger in this repo is acceptable. That
was already adjudicated structurally, before you were spawned, by
fm_gates_classify in bin/fm-gates-lib.sh - the only authority on it. Do not
re-derive, restate, or override that rule, and do not run gates/verify.sh: it
re-runs every gate and rewrites the ledger in this worktree. A red gate
declared in gates/accepted-red.md is accepted on purpose and is not a finding.
You may still check that the tests THIS task claims to have added or changed
actually pass.

# The task brief
$BRIEF_TEXT

# Foreign-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
VERDICT: approve - <one-line reason>
VERDICT: reject - <the concrete failure a fix must address>
VERDICT: escalate - <why a human must decide>
EOF
)

verdict_kind=""
verdict_reason=""
if (cd "$WORKTREE" && sh -c "$VERIFY_CMD \"\$1\"" _ "$PROMPT") > "$REPORT" 2>&1; then
  line=$(grep -E '^VERDICT: (approve|reject|escalate)' "$REPORT" | tail -1 || true)
  if [ -n "$line" ]; then
    verdict_kind=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate).*$/\1/')
    verdict_reason=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate)[^A-Za-z0-9]*//')
  fi
fi
if [ -z "$verdict_kind" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "verifier infrastructure failure (no VERDICT line; see data/$ID/verify-report.md) - fail closed"
  echo "escalate: verifier produced no verdict for $ID (see $REPORT)" >&2
  exit 3
fi

# --- 5. record + route ----------------------------------------------------------
case "$verdict_kind" in
  approve)
    fm_verdict_append "$STATE" "$ID" approve "${verdict_reason:-verifier approve} (lens=$LENS)"
    echo "approve: task $ID verified (lens=$LENS)"
    exit 0
    ;;
  escalate)
    fm_verdict_append "$STATE" "$ID" escalate "${verdict_reason:-verifier escalate}"
    echo "escalate: task $ID needs the captain (see $REPORT)" >&2
    exit 3
    ;;
  reject)
    n=$(( $(fm_verdict_reject_count "$STATE" "$ID") + 1 ))
    fm_verdict_append "$STATE" "$ID" reject "(attempt $n of $MAX) ${verdict_reason:-verifier reject}"
    # shellcheck disable=SC2086 # FM_RELAY_CMD is deliberately word-split
    ${FM_RELAY_CMD:-"$SCRIPT_DIR/fm-send.sh"} "fm-$ID" \
      "QUARTERDECK REJECTED (attempt $n of $MAX): ${verdict_reason:-see report}. Findings: data/$ID/verify-report.md and data/$ID/lens-review.md. Fix and append a fresh done: line." \
      || echo "warning: could not relay reject to fm-$ID (window gone?)" >&2
    if [ "$n" -ge "$MAX" ]; then
      fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($n rejects); captain decision required"
      echo "escalate: task $ID hit the attempt cap ($n of $MAX)" >&2
      exit 3
    fi
    echo "reject: task $ID (attempt $n of $MAX); findings relayed" >&2
    exit 2
    ;;
esac
