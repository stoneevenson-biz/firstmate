#!/usr/bin/env bash
# GATE h6 - FM_MUX=tmux reproduces the pre-seam behaviour BYTE-IDENTICALLY.
#
# WHY A CALL-SEQUENCE GOLDEN AND NOT "it still seems to work". FM_MUX=tmux is
# the rollback switch and the supported driver for every headless context - cron,
# CI, a plain SSH session with no herdr server. A rollback that runs a
# similar-looking code path is not a rollback. So this gate pins the EXACT
# sequence of tmux invocations fm-spawn emits, in order, argument for argument.
#
# HOW THE GOLDEN WAS PRODUCED. By running the pre-seam bin/fm-spawn.sh - the one
# that called tmux directly, with no FM_MUX or fm_mux_ reference anywhere in it -
# against this same fixture and capturing its calls. It is the observed truth of
# the old code, not a description of it.
#
# WHAT IT ALREADY CAUGHT. Routing `treehouse get` through the same verb as the
# launch line changed one call from `send-keys <cmd> Enter` into `send-keys -l
# <cmd>` plus a separate `Enter`. Behaviourally equivalent, near certainly
# harmless - and not byte-identical, so the tmux driver keeps both shapes.
# That distinction is only visible because this gate compares calls.
set -u
export FM_MUX=tmux
export FM_INTAKE_OVERRIDE=1   # wardroom: this suite tests spawn machinery, not intake
export FM_SKIP_SHELL_READY=1  # the readiness probe mints a random marker; h7 covers it live
export FM_LAUNCH_VERIFY_SLEEP=0
export FM_MUX_ENTER_SLEEP=0

# shellcheck source=tests/mux-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/mux-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux-h6)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" treehouse

PROJ="$TMP_ROOT/proj"
git init -q -b main "$PROJ"
git -C "$PROJ" commit -q --allow-empty -m init
git -C "$PROJ" worktree add -q --detach "$TMP_ROOT/wt" >/dev/null 2>&1
WT=$(cd "$TMP_ROOT/wt" && pwd -P)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/parity-p1"
printf 'brief\n' > "$HOME_DIR/data/parity-p1/brief.md"
CALLS="$TMP_ROOT/calls"; export CALLS
PROJ_LOGICAL=$(cd "$PROJ" && pwd)
PROJ_REAL=$(cd "$PROJ" && pwd -P)
HOME_LOGICAL=$(cd "$HOME_DIR" && pwd)
HOME_REAL=$(cd "$HOME_DIR" && pwd -P)

# The golden, with the fixture's absolute paths replaced by stable tokens.
# @PROJ@ project checkout   @HOME@ firstmate home   (the worktree never appears)
read -r -d '' GOLDEN <<'GOLD' || true
display-message -p #S
list-windows -t firstmate -F #{window_name}
new-window -d -t firstmate: -n fm-parity-p1 -c @PROJ@
send-keys -t firstmate:fm-parity-p1 treehouse get Enter
display-message -p -t firstmate:fm-parity-p1 #{pane_current_path}
send-keys -t firstmate:fm-parity-p1 -l FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME='@HOME@' codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch '@HOME@/state/parity-p1.turn-ended'\"]" "$(cat '@HOME@/data/parity-p1/brief.md')"
send-keys -t firstmate:fm-parity-p1 Enter
capture-pane -p -t firstmate:fm-parity-p1 -S -15
GOLD

capture_calls() {
  rm -rf "$HOME_DIR/state"
  : > "$CALLS"
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
    CALLS="$CALLS" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" parity-p1 "$PROJ" codex >/dev/null 2>&1
  # Normalise the fixture's absolute paths. Each is substituted in all three
  # shapes it can appear in - as written, logical (cd+pwd), and real (pwd -P) -
  # because mktemp under a TMPDIR with a trailing slash yields a doubled slash
  # that `cd`/`pwd` quietly collapses, and fm-spawn records the collapsed form.
  sed -e "s#$HOME_REAL#@HOME@#g" -e "s#$HOME_LOGICAL#@HOME@#g" -e "s#$HOME_DIR#@HOME@#g" \
      -e "s#$PROJ_REAL#@PROJ@#g" -e "s#$PROJ_LOGICAL#@PROJ@#g" -e "s#$PROJ#@PROJ@#g" "$CALLS"
}

# --- the parity gate --------------------------------------------------------

test_tmux_call_sequence_is_byte_identical() {
  local got
  got=$(capture_calls)
  if [ "$got" = "$GOLDEN" ]; then
    pass "parity: FM_MUX=tmux emits the pre-seam tmux call sequence, byte for byte"
    return 0
  fi
  printf -- '--- expected (pre-seam) ---\n%s\n--- got (through the seam) ---\n%s\n' "$GOLDEN" "$got" >&2
  fail "the tmux driver diverged from pre-seam behaviour; FM_MUX=tmux is no longer a true rollback"
}

# The golden must be a real trace, not a shape that would match anything. If the
# seam stopped calling tmux entirely this would still pass on an empty capture
# unless the golden is non-trivial - so pin its substance too.
test_the_golden_is_not_vacuous() {
  local n
  n=$(printf '%s\n' "$GOLDEN" | grep -c .)
  if [ "$n" -lt 8 ]; then fail "the golden has only $n calls; it cannot be pinning much"; fi
  case "$GOLDEN" in
    *"new-window -d -t firstmate: -n fm-parity-p1"*) : ;;
    *) fail "the golden does not contain the window create" ;;
  esac
  case "$GOLDEN" in
    *"treehouse get Enter"*) : ;;
    *) fail "the golden does not contain the treehouse get call shape" ;;
  esac
  pass "parity: the golden is a real ${n}-call trace, not a shape that matches anything"
}

# The tmux window NAME is protocol, not decoration: fm-watch scans for `fm-*`
# and the meta's window= is <session>:<name>. The herdr work-naming must not
# have leaked into it.
test_tmux_window_naming_is_unchanged() {
  local meta
  capture_calls >/dev/null
  meta="$HOME_DIR/state/parity-p1.meta"
  assert_grep "window=firstmate:fm-parity-p1" "$meta" \
    "the tmux window name changed; fm-watch's fm-* scan and every recorded window= would break"
  assert_grep "mux=tmux" "$meta" "the tmux path did not record its driver"
  pass "parity: the tmux window is still firstmate:fm-parity-p1, and says so in the meta"
}

test_tmux_call_sequence_is_byte_identical
test_the_golden_is_not_vacuous
test_tmux_window_naming_is_unchanged
