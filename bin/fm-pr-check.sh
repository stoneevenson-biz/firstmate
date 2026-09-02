#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> to state/<id>.meta and arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff
# the PR is merged (the watcher's check contract: output = wake firstmate,
# silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
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

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
