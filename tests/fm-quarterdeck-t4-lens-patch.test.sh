#!/usr/bin/env bash
# T4: the foreign lens is never handed something that is not a patch.
#
# The Quarterdeck has two halves. The independent verifier re-runs the gates in
# the worktree; the foreign lens reads ONLY the payload file. So a payload that
# is corrupt, or that describes a different change, does not fail the gate - it
# silently halves it, which is the exact failure this repo exists to eliminate.
#
# The artifact that prompted this suite is real: data/fmcmd-guard/lens-diff.patch,
# 2026-09-02, exactly 200,000 bytes, cut mid-AWK-statement at an arbitrary byte.
# `git apply --check` answered `corrupt patch at line 3403`. It carried 7 commits
# where the branch owned 3, because the merge base was taken against a cached
# refs/remotes/origin/main that a failed fetch had left four merged commits
# stale. And it contained not one of the branch's own tests, because truncation
# by byte drops whatever sorts last and `tests/` sorts after `bin/` and `docs/`.
#
# One case per property, one gate behind each, because a single "the patch is
# good" gate would go green the moment any one of the three was fixed:
#
#   scoped-to-branch     the range is the branch's own base, proved against a
#                        fixture whose base is deliberately noisy - a stale
#                        remote-tracking ref plus an unreachable origin, which
#                        is the pooled-clone shape the defect arrived in
#   file-boundary-split  a diff over the bound drops whole FILES and NAMES them;
#                        the artifact still passes `git apply --check`
#   refuses-corrupt      a payload that is not a valid patch refuses the lens
#                        instead of passing it through
#   keeps-own-tests      the branch's own test files survive a bound that forces
#                        omission - that omission is what made fmcmd-guard useless
#
# Two more were added on 2026-09-02 after a foreign lens read the SHIPPED
# version of this code and found the same class of defect twice more. Both are
# reproduced in their cases; neither was theorised:
#
#   base-from-configured-remotes
#                        a ref under refs/remotes/ is not evidence that a remote
#                        exists, and the crewmate under review can write one -
#                        `git update-ref refs/remotes/fake/main HEAD^` moved the
#                        base and hid a commit and a file of the branch's own
#                        work behind a perfectly valid patch
#   bound-covers-payload the bound counted only the diff bodies while the header
#                        carried one line per commit and one per omitted path -
#                        900 files under a 2000-byte bound wrote 81,411 bytes
#
# Mutation (LEDGER_MUTATE=1): every case asserts the DEFECT instead - noise in
# the patch, a corrupt artifact, a lens run on rubbish, absent tests. A correct
# implementation then fails the case, which is what freeze demands.
#
# No network, no lens, no verifier model: FM_LENS_CMD and FM_VERIFY_CMD are
# stubs, and the fixture origin is a file:// URL that deliberately does not
# exist, so the one fetch fm-verify makes fails fast and locally.
#
# Usage: bash tests/fm-quarterdeck-t4-lens-patch.test.sh [<case>...]  (default: all)
# spec: docs/specs/2026-09-02-lens-patch-integrity.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MUTATE="${LEDGER_MUTATE:-0}"

TMP=$(fm_test_tmproot fm-qd-t4-lens-patch)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
export FM_RELAY_CMD=true
fm_git_identity

LENS_LIB="$ROOT/bin/fm-patch-lib.sh"

# --- the noisy-base fixture --------------------------------------------------
#
# A pooled clone's shape, reproduced exactly: the local default branch is
# current, the cached refs/remotes/origin/<default> is several commits stale,
# and origin itself cannot be reached to refresh it. Nothing here reads the
# machine it runs on - the suite chooses the root and reads the default branch
# name back out of the fixture rather than assuming main.
#
# fixture <name> [own-file-body-generator]
#   echoes "<proj>|<worktree>|<default-branch>"
fixture() {
  local name=$1 proj wt def i
  proj="$TMP/$name"; wt="$TMP/$name-wt"
  fm_git_init_commit "$proj"
  def=$(git -C "$proj" symbolic-ref --quiet --short HEAD)

  # The stale cached remote-tracking ref, pinned at the first commit, plus an
  # origin URL that resolves to nothing so the fetch cannot repair it.
  git -C "$proj" update-ref "refs/remotes/origin/$def" "$(git -C "$proj" rev-parse HEAD)"
  git -C "$proj" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$def"
  git -C "$proj" remote add origin "file://$TMP/there-is-no-origin-here.git"

  # NOISE: two unrelated commits that land on the default branch after the
  # cached ref was taken. They are already somebody else's landed work.
  mkdir -p "$proj/noise"
  for i in 1 2 3 4 5 6; do printf 'noise one %s\n' "$i" > "$proj/noise/a$i.txt"; done
  git -C "$proj" add noise
  git -C "$proj" commit -qm "noise: the first unrelated landing"
  for i in 1 2 3 4 5 6; do printf 'noise two %s\n' "$i" > "$proj/noise/b$i.txt"; done
  git -C "$proj" add noise
  git -C "$proj" commit -qm "noise: the second unrelated landing"

  git -C "$proj" worktree add --quiet -b "fm/$name" "$wt" "$def"
  printf '%s|%s|%s\n' "$proj" "$wt" "$def"
}

# own_commit <worktree> <bin-lines> <test-lines>: the branch's own work, one
# source file and one test file, sized by the caller so a bound can be aimed.
own_commit() {
  local wt=$1 binlines=$2 testlines=$3 i
  mkdir -p "$wt/bin" "$wt/tests"
  {
    printf '#!/usr/bin/env bash\n'
    for i in $(seq 1 "$binlines"); do printf 'echo "the branch own source line %s"\n' "$i"; done
  } > "$wt/bin/thing.sh"
  {
    printf '#!/usr/bin/env bash\n'
    for i in $(seq 1 "$testlines"); do printf 'echo "the branch own test line %s"\n' "$i"; done
  } > "$wt/tests/thing.test.sh"
  git -C "$wt" add bin tests
  git -C "$wt" commit -qm "task: the work this branch actually owns"
}

# --- fm-verify harness -------------------------------------------------------
#
# The lens stub records that it ran AND keeps the payload it was given, so a
# case can assert both "the lens was refused" and "what the lens saw".
setup_stubs() {
  LENS_LOG="$TMP/lens.invocations"
  LENS_SEEN="$TMP/lens.stdin"
  : > "$LENS_LOG"
  : > "$LENS_SEEN"
  cat > "$TMP/lens.sh" <<SH
#!/usr/bin/env bash
echo ran >> "$LENS_LOG"
cat > "$LENS_SEEN"
echo "stub lens review"
SH
  cat > "$TMP/verifier.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: approve - stub verifier"
SH
  chmod +x "$TMP/lens.sh" "$TMP/verifier.sh"
  export FM_LENS_CMD="$TMP/lens.sh"
  export FM_VERIFY_CMD="$TMP/verifier.sh"
}

# run_verify <id> <proj> <wt> [max-bytes] -> writes $TMP/verify.out, echoes exit code
run_verify() {
  local id=$1 proj=$2 wt=$3 maxb=${4:-}
  mkdir -p "$D/$id"
  fm_write_meta "$S/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" \
    "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
  local code
  if [ -n "$maxb" ]; then
    FM_LENS_PATCH_MAX_BYTES="$maxb" "$ROOT/bin/fm-verify.sh" "$id" > "$TMP/verify.out" 2>&1
  else
    "$ROOT/bin/fm-verify.sh" "$id" > "$TMP/verify.out" 2>&1
  fi
  code=$?
  printf '%s\n' "$code"
}

# patch_base <patch>: the base commit the builder recorded in its own header.
patch_base() {
  sed -n 's/^# range: \([0-9a-f][0-9a-f]*\)\.\.HEAD.*/\1/p' "$1" | head -1
}

# ============================================================================
case_scoped_to_branch() {
  local f proj wt id=t4scope patch code
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  own_commit "$wt" 20 10
  setup_stubs
  code=$(run_verify "$id" "$proj" "$wt")
  patch="$D/$id/lens-diff.patch"
  [ -f "$patch" ] || fail "scoped-to-branch: no payload was written (exit $code): $(cat "$TMP/verify.out")"

  if [ "$MUTATE" = 1 ]; then
    assert_grep "diff --git a/noise/a1.txt" "$patch" \
      "MUTATION: the payload was expected to carry the unrelated landings"
    return 0
  fi

  assert_grep "diff --git a/bin/thing.sh" "$patch" "the branch's own source must be in the patch"
  assert_grep "diff --git a/tests/thing.test.sh" "$patch" "the branch's own test must be in the patch"
  assert_no_grep "noise/a1.txt" "$patch" \
    "a commit that already landed on the default branch is not this branch's change"
  assert_no_grep "noise/b1.txt" "$patch" \
    "the second unrelated landing must not ride along either"
  assert_grep "task: the work this branch actually owns" "$patch" \
    "the header must list the branch's own commit"
  assert_no_grep "noise: the first unrelated landing" "$patch" \
    "the header must not list commits the branch does not own"
  pass "scoped-to-branch: the range is the branch's own base, not a stale ref's"
}

# ============================================================================
case_file_boundary_split() {
  local f proj wt id=t4split patch base included declared
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  own_commit "$wt" 400 400
  setup_stubs
  # A bound that one file clears and the pair does not, so omission is forced.
  run_verify "$id" "$proj" "$wt" 20000 >/dev/null
  patch="$D/$id/lens-diff.patch"
  [ -f "$patch" ] || fail "file-boundary-split: no payload was written: $(cat "$TMP/verify.out")"
  base=$(patch_base "$patch")
  [ -n "$base" ] || fail "file-boundary-split: the payload header names no range"

  if [ "$MUTATE" = 1 ]; then
    bash "$LENS_LIB" check "$wt" "$base" "$patch" >/dev/null 2>&1 \
      && fail "MUTATION: the bounded payload was expected to be a corrupt patch"
    return 0
  fi

  bash "$LENS_LIB" check "$wt" "$base" "$patch" >/dev/null 2>&1 \
    || fail "a bounded payload must still be a valid patch: $(bash "$LENS_LIB" check "$wt" "$base" "$patch" 2>&1)"
  assert_grep "# OMITTED" "$patch" "an omission must be announced in the payload itself"
  assert_grep "would exceed the 20000-byte payload bound" "$patch" \
    "the omission must name the reason, not just the fact"
  # Every file in the payload is whole: the count of file headers equals the
  # count the header declares, so nothing was half-written.
  included=$(grep -c '^diff --git ' "$patch" || true)
  declared=$(sed -n 's/^# files changed in this range: [0-9]* (included \([0-9]*\).*/\1/p' "$patch" | head -1)
  [ -n "$declared" ] || fail "file-boundary-split: the header declares no included count"
  [ "$included" = "$declared" ] \
    || fail "file-boundary-split: header declares $declared included files, payload carries $included"

  # A file must never leave the payload without being named, and the arithmetic
  # above cannot see a file lost between the inventory and the body. git permits
  # a NEWLINE inside a path, so a builder that inventories NUL-delimited and then
  # re-joins on newlines splits one such path into two fragments naming no file:
  # the real file vanishes from the patch and two inventions are blamed for it.
  # Measured on this implementation before the fix; one file changed, none in the
  # payload, two omissions named that were never files.
  local nl proj2 wt2 base2 out2 weird
  nl="$TMP/nlfix"; proj2="$nl/proj"; wt2="$nl/wt"
  mkdir -p "$nl"
  fm_git_init_commit "$proj2"
  git -C "$proj2" worktree add --quiet -b fm/nl "$wt2" \
    "$(git -C "$proj2" symbolic-ref --quiet --short HEAD)"
  base2=$(git -C "$wt2" rev-parse HEAD)
  weird=$(printf 'awkward\nname.txt')
  printf 'ordinary\n' > "$wt2/ordinary.txt"
  printf 'content\n' > "$wt2/$weird"
  git -C "$wt2" add -A
  git -C "$wt2" commit -qm "a path with a newline in it"
  out2="$nl/out.patch"
  bash "$LENS_LIB" build "$wt2" "$base2" "$out2" 200000 >/dev/null 2>&1 \
    || fail "file-boundary-split: a newline in a path must not make the payload unusable"
  assert_grep "files changed in this range: 2 (included 2, omitted 0)" "$out2" \
    "a path containing a newline is one file, and it must reach the payload"
  assert_no_grep "produced no diff for it" "$out2" \
    "no invented path fragment may be blamed for an omission that did not happen"
  bash "$LENS_LIB" check "$wt2" "$base2" "$out2" >/dev/null 2>&1 \
    || fail "file-boundary-split: the newline-path payload must still be a valid patch"

  pass "file-boundary-split: a bound drops whole named files and leaves a valid patch"
}

# ============================================================================
case_refuses_corrupt() {
  local f proj wt id=t4corrupt patch base full cut lines code

  # (a) The rule's own implementation, asked directly: a patch cut mid-hunk -
  # the fmcmd-guard shape - is not a valid patch and says so.
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  own_commit "$wt" 60 10
  base=$(git -C "$wt" rev-parse HEAD~1)
  full="$TMP/full.patch"; cut="$TMP/cut.patch"
  git -C "$wt" diff --no-renames "$base" HEAD -- bin/thing.sh > "$full"
  lines=$(wc -l < "$full" | tr -d ' ')
  { head -n "$((lines - 4))" "$full"; printf '+an incomplete fina'; } > "$cut"

  if [ "$MUTATE" = 1 ]; then
    bash "$LENS_LIB" check "$wt" "$base" "$cut" >/dev/null 2>&1 \
      || fail "MUTATION: the truncated patch was expected to pass as valid"
  else
    bash "$LENS_LIB" check "$wt" "$base" "$full" >/dev/null 2>&1 \
      || fail "a whole patch must check out clean"
    bash "$LENS_LIB" check "$wt" "$base" "$cut" >/dev/null 2>&1 \
      && fail "a patch cut mid-hunk must be refused, not accepted"
    assert_contains "$(bash "$LENS_LIB" check "$wt" "$base" "$cut" 2>&1)" \
      "not a valid patch" "the refusal must say what it refused"
  fi

  # (b) The wiring: when no usable patch exists, the lens is not run at all.
  # A bound of one byte omits every file, so the payload carries no diff -
  # the same rail a corrupt one takes, and the only one reachable through
  # fm-verify by input alone. The apply check behind it is a BACKSTOP: the
  # builder assembles the payload from per-file diffs of the very range it
  # checks against, so a corrupt one is unreachable by construction, which is
  # exactly why (a) asks the check directly with a patch built to be corrupt
  # rather than contriving a test-only door into fm-verify to reach it.
  setup_stubs
  code=$(run_verify "$id" "$proj" "$wt" 1)
  patch="$D/$id/lens-diff.patch"

  if [ "$MUTATE" = 1 ]; then
    assert_present "$LENS_LOG" "MUTATION: lens log missing"
    [ -s "$LENS_LOG" ] || fail "MUTATION: the lens was expected to run on the unusable payload"
    return 0
  fi

  [ ! -s "$LENS_LOG" ] \
    || fail "the lens must be refused, not handed a payload with no diff in it"
  expect_code 0 "$code" "refusing the lens must degrade, not fail the stage: $(cat "$TMP/verify.out")"
  assert_grep "lens: none" "$S/$id.verdict" "the refusal must be recorded as no lens at all"
  assert_contains "$(cat "$TMP/verify.out")" "REFUSED" \
    "the refusal must be loud on the operator's channel"
  assert_grep "VERDICT" "$D/$id/verify-report.md" \
    "the independent verifier is unaffected and must still run"
  [ -f "$patch" ] || fail "refuses-corrupt: the payload should still be on disk for inspection"
  pass "refuses-corrupt: an unusable payload refuses the lens instead of passing it through"
}

# ============================================================================
case_keeps_own_tests() {
  local f proj wt id=t4tests patch
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  # The source file is far larger than the test file, and git's own path order
  # puts bin/ first: a bound spent in path order buys the source and drops the
  # tests, which is exactly what happened to fmcmd-guard.
  own_commit "$wt" 400 15
  setup_stubs
  # 4000: the bodies get 3000 of it, which the ~700-byte test diff clears and
  # the ~15,600-byte source diff does not, and the header's share still has room
  # to NAME what it dropped. (Under the old semantics the header was unbounded,
  # so any body budget would do; it is budgeted now - see bound-covers-payload.)
  run_verify "$id" "$proj" "$wt" 4000 >/dev/null
  patch="$D/$id/lens-diff.patch"
  [ -f "$patch" ] || fail "keeps-own-tests: no payload was written: $(cat "$TMP/verify.out")"

  if [ "$MUTATE" = 1 ]; then
    assert_no_grep "diff --git a/tests/thing.test.sh" "$patch" \
      "MUTATION: the branch's own tests were expected to be dropped"
    return 0
  fi

  assert_grep "diff --git a/tests/thing.test.sh" "$patch" \
    "the branch's own tests must survive a bound that forces omission"
  assert_grep "bin/thing.sh - " "$patch" \
    "the file the bound did drop must be named in the payload"
  assert_no_grep "diff --git a/bin/thing.sh" "$patch" \
    "a file named as omitted must genuinely be absent"
  pass "keeps-own-tests: a bound spends itself on the tests first, and names what it dropped"
}

# ============================================================================
case_base_from_configured_remotes() {
  # A ref under refs/remotes/ is not evidence that a remote exists. It is just a
  # ref, and the crewmate whose work is under review can write one - so the
  # author of the code being reviewed could choose where the review starts.
  #
  # The control comes first, against a repo with NO configured remotes at all,
  # because a guard against a forgery that does not work proves nothing.
  local f proj wt id=t4forge patch base1 base2 nfiles
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  own_commit "$wt" 20 10
  # A second commit, so there is an earlier one for a forged base to hide.
  printf 'echo "a second commit of the branch own work"\n' >> "$wt/bin/thing.sh"
  git -C "$wt" add bin
  git -C "$wt" commit -qm "task: the second commit this branch owns"

  # The fixture's origin is unreachable, so its remote-tracking ref is stale and
  # refs/heads/<default> is the honest base. Strip the configured remote too, so
  # the forged ref is the ONLY refs/remotes entry in play.
  git -C "$proj" remote remove origin
  git -C "$proj" update-ref -d "refs/remotes/origin/$(printf '%s' "$f" | cut -d'|' -f3)" 2>/dev/null || true

  base1=$(bash "$LENS_LIB" base "$wt" 2>/dev/null)
  [ -n "$base1" ] || fail "base-from-configured-remotes: no honest base resolved"

  git -C "$wt" update-ref "refs/remotes/forged/$(printf '%s' "$f" | cut -d'|' -f3)" \
    "$(git -C "$wt" rev-parse 'HEAD^')"
  base2=$(bash "$LENS_LIB" base "$wt" 2>/dev/null)

  if [ "$MUTATE" = 1 ]; then
    [ "$base2" = "$(git -C "$wt" rev-parse 'HEAD^')" ] \
      || fail "MUTATION: expected a forged remote-tracking ref to move the base"
    return 0
  fi

  [ "$base2" = "$base1" ] \
    || fail "a ref under refs/remotes/ whose remote this clone does not configure must not move the base (honest $base1, after forgery $base2)"

  # And end to end: both of the branch's own commits still reach the lens.
  setup_stubs
  run_verify "$id" "$proj" "$wt" >/dev/null
  patch="$D/$id/lens-diff.patch"
  assert_grep "task: the work this branch actually owns" "$patch" \
    "the earlier commit a forged base would have hidden must still be in the patch"
  assert_grep "task: the second commit this branch owns" "$patch" \
    "the later commit must be there too"
  nfiles=$(grep -c '^diff --git ' "$patch" || true)
  [ "$nfiles" -ge 2 ] || fail "the forged base hid the branch's own files (saw $nfiles)"
  pass "base-from-configured-remotes: only a remote this clone configures can move the lens base"
}

# ============================================================================
case_bound_covers_payload() {
  # The bound is a promise about the ARTIFACT, not about one section of it. An
  # earlier round budgeted only the diff bodies and then prepended a header
  # carrying one line per commit and one line per omitted path, both unbounded:
  # a 900-file branch under a 2000-byte bound wrote 81,411 bytes, forty times
  # the number it claimed, every byte of it header. The lens's context is the
  # thing being protected, so the header counts.
  local f proj wt id=t4bound out base i bytes bound=2000
  f=$(fixture "$id"); proj=${f%%|*}; wt=$(printf '%s' "$f" | cut -d'|' -f2)
  mkdir -p "$wt/many"
  for i in $(seq 1 300); do
    printf 'one line of file %s, padded well past any per-file share of the budget\n' "$i" \
      > "$wt/many/file-$i.txt"
  done
  git -C "$wt" add many
  git -C "$wt" commit -qm "task: three hundred files"
  base=$(git -C "$wt" rev-parse 'HEAD^')
  out="$TMP/$id.patch"

  bash "$LENS_LIB" build "$wt" "$base" "$out" "$bound" >/dev/null 2>&1 || true
  [ -f "$out" ] || fail "bound-covers-payload: nothing was written"
  bytes=$(wc -c < "$out" | tr -d ' ')

  if [ "$MUTATE" = 1 ]; then
    [ "$bytes" -gt "$bound" ] \
      || fail "MUTATION: expected the payload to overrun its own bound (got $bytes <= $bound)"
    return 0
  fi

  [ "$bytes" -le "$bound" ] \
    || fail "the payload is $bytes bytes against a ${bound}-byte bound; a bound the artifact does not obey is not a bound"
  assert_grep "elided to keep this payload inside its" "$out" \
    "a header that had to stop must say how much it left out"

  # The same at the real default bound, where nothing should need eliding and
  # the artifact must still be a patch.
  bash "$LENS_LIB" build "$wt" "$base" "$TMP/$id-full.patch" 200000 >/dev/null 2>&1 \
    || fail "bound-covers-payload: the default bound must still produce a usable payload"
  bytes=$(wc -c < "$TMP/$id-full.patch" | tr -d ' ')
  [ "$bytes" -le 200000 ] || fail "the default-bound payload is $bytes bytes"
  bash "$LENS_LIB" check "$wt" "$base" "$TMP/$id-full.patch" >/dev/null 2>&1 \
    || fail "bound-covers-payload: the bounded payload must still be a valid patch"
  pass "bound-covers-payload: the bound counts the whole artifact, header included"
}

# ============================================================================
ALL_CASES="scoped-to-branch file-boundary-split refuses-corrupt keeps-own-tests
           base-from-configured-remotes bound-covers-payload"

run_case() {
  case "$1" in
    scoped-to-branch)    case_scoped_to_branch ;;
    file-boundary-split) case_file_boundary_split ;;
    refuses-corrupt)     case_refuses_corrupt ;;
    keeps-own-tests)     case_keeps_own_tests ;;
    base-from-configured-remotes) case_base_from_configured_remotes ;;
    bound-covers-payload)         case_bound_covers_payload ;;
    *) fail "unknown case '$1'; known: $ALL_CASES" ;;
  esac
}

if [ $# -gt 0 ]; then
  for c in "$@"; do run_case "$c"; done
else
  # shellcheck disable=SC2086  # the case list is a deliberate word list
  for c in $ALL_CASES; do run_case "$c"; done
fi
