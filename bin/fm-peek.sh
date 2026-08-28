#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare firstmate window name (fm-xyz), resolved through
#   this home's state/<id>.meta, or an explicit opaque multiplexer target
#   (session:window under tmux, a pane id under herdr). A RAW target carries no
#   meta, so it is read as a tmux session:window unless FM_MUX says otherwise.
#
# The read goes through the multiplexer seam (bin/fm-mux-lib.sh), and through
# the driver that MINTED the target - recorded as mux= in the task's meta by
# fm-spawn - not whichever driver happens to resolve now. A crewmate spawned as
# a herdr tab must stay peekable even if the herdr server blips, and a tmux
# crewmate must never be probed with herdr verbs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-mux-lib.sh
. "$SCRIPT_DIR/fm-mux-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

fm_mux_resolve "$1" "$STATE" || exit 1
N=${2:-40}
fm_mux_read "$FM_MUX_TARGET" "$N"
