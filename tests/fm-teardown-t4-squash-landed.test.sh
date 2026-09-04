#!/usr/bin/env bash
# GATE t4-squash-landed - a squash-merged branch is torn down; unproven work is not.
#
# THE DEFECT THIS FREEZES. bin/fm-teardown.sh asked one question of a finished
# ship task: is HEAD reachable from any remote-tracking branch? Squash-merging a
# PR with --delete-branch answers NO for work that is completely landed. The
# merge replays the whole branch as ONE new commit on the default branch and
# deletes the branch, so not one of the branch's own commits is reachable from
# any remote ever again. Observed 2026-09-02: six merged worktrees all refused
# with "has work not on any remote", the treehouse pool ran to zero available
# slots, and the next dispatch died with
# `treehouse get did not enter a worktree within 60s`. Hygiene stopped being
# automatic and the pool silently filled until the fleet could not dispatch.
#
# THE FIX IS A PROOF, NOT A RELAXATION, and that is what this gate pins. Both
# halves are asserted in the same file so neither can be "fixed" by breaking the
# other:
#   * a squash-merged-and-deleted branch IS torn down - the content is proven to
#     be on the default branch by patch-id, the only evidence a squash leaves;
#   * genuinely unpushed work is STILL refused - as is work whose content was
#     changed on the way in, and any worktree with uncommitted changes, because
#     no merge can have landed a diff that exists only in a working tree.
#
# The stale-ref case matters as much as the merge itself: a pooled clone's
# remote-tracking ref is older than the merge that just landed, so the proof has
# to refresh it once and retry rather than concluding "not landed" from a ref
# that predates the answer. Case (a) deliberately never fetches by hand.
#
# Mutation (LEDGER_MUTATE=1): change one line of the squashed content on the
# default branch, so the landed patch is no longer the branch's patch. A correct
# teardown then refuses - which is exactly right, and fails case (a)'s assertion,
# proving the ALLOW is keyed to the patch-id match and not to "a merge happened".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-t4-squash)

G="-c user.email=t@t -c user.name=t"

# make_case <name>: a bare origin, a project clone of it, and a worktree on
# branch fm/task-x1 carrying two commits that touch feature.txt.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'baseline\n' > "$case_dir/_seed/README.md"
  # shellcheck disable=SC2086  # $G is a deliberate word-split identity flag pair
  git -C "$case_dir/_seed" add README.md
  # shellcheck disable=SC2086
  git -C "$case_dir/_seed" $G commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  printf 'one\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  # shellcheck disable=SC2086
  git -C "$case_dir/wt" $G commit -qm "feature: part one"
  printf 'one\ntwo\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  # shellcheck disable=SC2086
  git -C "$case_dir/wt" $G commit -qm "feature: part two"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 mode=${2:-no-mistakes}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode"
}

# squash_into_origin_main <case_dir> [mutate]: what GitHub's "Squash and merge"
# with --delete-branch leaves behind - one new commit on main carrying the whole
# branch diff, and no branch anywhere. The branch was never pushed, so there is
# nothing on the remote to delete; that IS the post-merge state for this task.
squash_into_origin_main() {
  local case_dir=$1 mutate=${2:-0}
  local clone="$case_dir/_squash"
  git clone -q "$case_dir/origin.git" "$clone"
  git -C "$clone" fetch -q "$case_dir/project" 'refs/heads/fm/task-x1:refs/heads/incoming'
  git -C "$clone" merge -q --squash incoming
  if [ "$mutate" = 1 ]; then
    # The maintainer changed the content on the way in. Landed, but not THIS patch.
    printf 'one\ntwo\nthree\n' > "$clone/feature.txt"
    git -C "$clone" add feature.txt
  fi
  # shellcheck disable=SC2086
  git -C "$clone" $G commit -qm "feature (#42)"
  git -C "$clone" push -q origin main
  rm -rf "$clone"
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# --- (a) the defect: squash-merged and deleted, and the ref is stale ---------

test_a_squash_merged_branch_is_torn_down() {
  local case_dir rc
  case_dir=$(make_case squashed)
  write_meta "$case_dir"
  squash_into_origin_main "$case_dir" "${LEDGER_MUTATE:-0}"

  # Deliberately NOT fetched: a pooled clone's remote-tracking ref is older than
  # the merge that just landed, and concluding "not landed" from a ref that
  # predates the answer is the same false refusal by another route.
  git -C "$case_dir/project" rev-parse --verify --quiet 'refs/remotes/origin/main' >/dev/null \
    || fail "fixture: the clone has no origin/main to be stale"
  [ "$(git -C "$case_dir/project" rev-parse refs/remotes/origin/main)" \
    != "$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)" ] \
    || fail "fixture: origin/main is already current, so the stale-ref half is untested"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  if [ "$rc" != 0 ]; then
    fail "a squash-merged branch was refused teardown; the pool fills until dispatch fails"$'\n'"--- stderr ---"$'\n'"$(cat "$case_dir/stderr")"
  fi
  assert_grep 'squash-merged' "$case_dir/stdout" \
    "teardown did not say WHY it proceeded over commits that are on no remote"
  assert_absent "$case_dir/state/task-x1.meta" "the task's meta survived a successful teardown"
  pass "t4: a squash-merged, branch-deleted task is torn down (proof, over a stale ref)"
}

# --- (b) the half that stops this becoming "always tear down" ----------------

test_genuinely_unpushed_work_is_still_refused() {
  local case_dir rc
  case_dir=$(make_case unpushed)
  write_meta "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "work that was never merged anywhere was torn down"
  assert_grep 'REFUSED' "$case_dir/stderr" "the refusal is not reported as a refusal"
  assert_grep 'not on '"$(printf 'origin/main')" "$case_dir/stderr" \
    "the refusal does not say the squash check was made and did not prove anything"
  assert_present "$case_dir/state/task-x1.meta" "a refused teardown still cleared the task's meta"
  pass "t4: genuinely unpushed work is still refused, and says the squash check failed too"
}

# Landed, but not THIS content. The proof must be of the branch's own patch, not
# of "some merge happened near here" - otherwise it is the relaxation the brief
# forbids, wearing a proof's clothes.
test_content_changed_on_the_way_in_is_refused() {
  local case_dir rc
  case_dir=$(make_case changed)
  write_meta "$case_dir"
  squash_into_origin_main "$case_dir" 1

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "a merge that changed the branch's content was accepted as proof of it"
  assert_grep 'REFUSED' "$case_dir/stderr" "the refusal is not reported as a refusal"
  pass "t4: a merge carrying different content proves nothing and is refused"
}

# No merge can have landed a diff that exists only in a working tree.
test_uncommitted_changes_are_refused_even_when_the_commits_landed() {
  local case_dir rc
  case_dir=$(make_case dirty)
  write_meta "$case_dir"
  squash_into_origin_main "$case_dir"
  printf 'uncommitted\n' > "$case_dir/wt/scratch.txt"
  git -C "$case_dir/wt" add scratch.txt

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "a dirty worktree was torn down because its commits had landed"
  assert_grep 'uncommitted changes present' "$case_dir/stderr" \
    "the refusal does not name the uncommitted work it is protecting"
  # The whole refusal, not a truncated one: a `[ -n "$x" ] && echo` under set -e
  # stops the block the moment the test is false and drops every later line.
  assert_grep 'Push the branch' "$case_dir/stderr" \
    "the refusal stopped early and never told the operator what to do about it"
  pass "t4: uncommitted work is refused even when the committed work provably landed"
}

# The same false refusal reaches local-only projects, where the captain may have
# squashed the branch into local main by hand.
test_local_only_squash_into_local_main_is_torn_down() {
  local case_dir rc
  case_dir=$(make_case local-squash)
  write_meta "$case_dir" local-only
  git -C "$case_dir/project" merge -q --squash fm/task-x1
  # shellcheck disable=SC2086
  git -C "$case_dir/project" $G commit -qm "feature, squashed locally"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  if [ "$rc" != 0 ]; then
    fail "a local-only task squashed into local main was refused teardown"$'\n'"--- stderr ---"$'\n'"$(cat "$case_dir/stderr")"
  fi
  assert_grep 'squash-merged' "$case_dir/stdout" "teardown did not say why it proceeded"
  pass "t4: a local-only branch squashed into local main is torn down"
}

test_a_squash_merged_branch_is_torn_down
test_genuinely_unpushed_work_is_still_refused
test_content_changed_on_the_way_in_is_refused
test_uncommitted_changes_are_refused_even_when_the_commits_landed
test_local_only_squash_into_local_main_is_torn_down
