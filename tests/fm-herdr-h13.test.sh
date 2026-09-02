#!/usr/bin/env bash
# GATE h13 - the workspace lookup fails CLOSED.
#
# THE DEFECT. Every workspace question was answered by its own
# `herdr workspace list 2>/dev/null | grep ...`, and the silence of a failed
# call was read as "no such workspace". So a herdr that was down, restarting, or
# answering something the parser does not understand looked exactly like a fleet
# with no workspaces - and the very next thing a caller does with that answer is
# CREATE one. A dropped socket would have duplicated the project's workspace and
# split its panes across the two, which is worse than the missing workspace the
# create was there to fix.
#
# "There are no workspaces" and "I could not ask" are opposite answers. They get
# different return codes, and only the first one may be acted on:
#   0 read, records on stdout   1 read, no match   2 could not read
#
# The blob-grep half is the same rule at the record level: a workspace id is
# READ OUT of a record and compared whole, never grepped for as a substring of
# the listing, so another field that happens to quote the id cannot answer for a
# workspace that does not exist.
#
# Mutation (LEDGER_MUTATE=1): the library is copied with the single fail-closed
# decision removed, so an unreadable listing degrades to an empty one - exactly
# the fail-open shape this gate forbids.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h13)
LIB="$ROOT/bin/fm-herdr.sh"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  LIB="$TMP_ROOT/mutated-fm-herdr.sh"
  # shellcheck disable=SC2016  # a literal sed pattern: it must not expand here
  sed 's/\[ "$ok" = 1 \] || return 2/:/' "$ROOT/bin/fm-herdr.sh" > "$LIB"
fi

FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
export HERDR_WORKSPACES="wJ=config,wM=archify"
export HERDR_WS_CREATED="$TMP_ROOT/created"
reset() { : > "$CALLS"; : > "$HERDR_WS_CREATED"; }

# shellcheck source=bin/fm-herdr.sh
. "$LIB"

# --- the three answers ------------------------------------------------------

test_the_reader_separates_cannot_ask_from_no_match() {
  local rc
  rc=0; fm_herdr_workspace_id archify >/dev/null || rc=$?
  assert_eq "$rc" 0 "a label that exists must resolve"
  rc=0; fm_herdr_workspace_id nosuch >/dev/null || rc=$?
  assert_eq "$rc" 1 "a label that is absent from a readable listing must be 'no match'"
  rc=0; HERDR_WS_RC=1 fm_herdr_workspace_id archify >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "a listing that could not be READ must not be reported as 'no match'"
  rc=0; HERDR_WS_RAW='{"error":{"code":"internal","message":"boom"}}' \
        fm_herdr_workspace_id archify >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "an answer that is not a workspace listing must not be reported as 'no match'"
  pass "lookup: 'no workspaces' and 'could not ask' are different answers"
}

# THE SHAPE A SUBSTRING TEST LETS THROUGH, and the one that actually reached
# `workspace create` in review: the call SUCCEEDS, the payload carries the magic
# `"workspaces":` text, and it is still not a listing. Each of these yields no
# records, and "no records" is the single answer that licenses a create.
test_a_payload_that_is_not_a_listing_is_refused_though_it_exits_zero() {
  local rc payload
  for payload in \
    '{"result":{"workspaces":BROKEN}}' \
    '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"af' \
    '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"archify"}]}}' \
    '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":['
  do
    rc=0
    HERDR_WS_RAW="$payload" fm_herdr_workspace_id archify >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "a zero-exit payload that is not a listing answered '$rc', not 'cannot tell': $payload"
    reset
    rc=0
    HERDR_WS_RAW="$payload" fm_herdr_workspace_for archify /p/archify >/dev/null 2>&1 || rc=$?
    [ "$rc" != 0 ] || fail "a zero-exit payload that is not a listing resolved a workspace: $payload"
    assert_no_grep "workspace create" "$CALLS" \
      "a malformed listing reached workspace create - the duplicate this reader exists to stop: $payload"
  done
  pass "lookup: a zero-exit payload that is not a listing is refused, never read as an empty fleet"
}

# The structural rule stated as its own case: every record must carry a complete
# id. A listing whose LAST record was cut off mid-key still opens, still closes
# its outer object, and would otherwise under-report the fleet by one workspace.
test_a_truncated_record_invalidates_the_listing() {
  local rc=0
  HERDR_WS_RAW='{"result":{"type":"workspace_list","workspaces":[{"label":"config","workspace_id":"wJ"},{"label":"archify","workspace_]}}' \
    fm_herdr_workspace_id config >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a listing with one truncated record answered '$rc' instead of refusing"
  pass "lookup: one truncated record invalidates the listing rather than shrinking the fleet"
}

# An EMPTY but well-formed listing is a real answer and must still be usable, or
# "fail closed" would just mean "never resolve anything".
test_an_empty_but_well_formed_listing_is_read_as_empty() {
  local rc=0
  HERDR_WORKSPACES="" fm_herdr_workspace_id archify >/dev/null || rc=$?
  assert_eq "$rc" 1 "an empty listing must read as 'no match', not as a failure"
  pass "lookup: an empty fleet is still a readable answer"
}

# --- the create decision ----------------------------------------------------

test_an_unreadable_listing_never_creates_a_workspace() {
  local rc out
  reset
  rc=0; out=$(HERDR_WS_RC=1 fm_herdr_workspace_for archify /p/archify 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "an unreadable listing resolved a workspace anyway: $out"
  assert_no_grep "workspace create" "$CALLS" \
    "an unreadable listing was treated as an empty fleet and a workspace was created"
  assert_contains "$out" "workspace list" "the refusal does not name what could not be read"
  reset
  rc=0; out=$(HERDR_WS_RAW='not json' fm_herdr_workspace_for archify /p/archify 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a malformed listing resolved a workspace anyway: $out"
  assert_no_grep "workspace create" "$CALLS" "a malformed listing was treated as an empty fleet"
  pass "create: an unreadable or malformed listing refuses instead of duplicating a workspace"
}

# The other direction, so the refusal above is a discrimination and not a block:
# a listing that really has no such workspace still creates one.
test_a_genuinely_absent_workspace_is_still_created() {
  local got
  reset
  got=$(fm_herdr_workspace_for brandnew /p/brandnew)
  assert_eq "$got" wNEW "an absent workspace must still be created"
  assert_grep "workspace create" "$CALLS" "the absent workspace was not created"
  pass "create: a genuinely absent workspace is still created"
}

# The override path asks the same question and must fail the same way.
test_the_override_path_fails_closed_too() {
  local rc=0 out
  reset
  out=$(FM_HERDR_WORKSPACE=wM HERDR_WS_RC=1 fm_herdr_workspace_for archify /p/archify 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "an override resolved against a listing that could not be read: $out"
  assert_no_grep "workspace create" "$CALLS" "the override path created a workspace on an unreadable listing"
  pass "create: FM_HERDR_WORKSPACE resolves against a readable listing or not at all"
}

# --- the blob-grep ----------------------------------------------------------

# A workspace id must be read out of a record, not grepped for as a substring of
# the whole listing: any other field that quotes the id answers a blob-grep.
test_existence_reads_the_id_out_of_a_record() {
  local rc=0
  rc=0; fm_herdr_workspace_exists wM || rc=$?
  assert_eq "$rc" 0 "a live workspace id must be found"
  rc=0; HERDR_WS_RAW='{"result":{"type":"workspace_list","workspaces":[{"label":"x","workspace_id":"wQ7"}],"focused_workspace_id":"wM"}}' \
        fm_herdr_workspace_exists wM || rc=$?
  assert_eq "$rc" 1 "another field quoting the id answered for a workspace that does not exist"
  rc=0; fm_herdr_workspace_exists w || rc=$?
  assert_eq "$rc" 1 "a partial id matched a longer one"
  rc=0; HERDR_WS_RC=1 fm_herdr_workspace_exists wM >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "an unreadable listing must not answer 'no such workspace'"
  pass "lookup: an id is read out of a record and compared whole, never grepped for"
}

# --- the reconcile CLI ------------------------------------------------------

test_reconcile_refuses_an_unreadable_fleet() {
  local rc=0 out home
  home="$TMP_ROOT/home"; mkdir -p "$home/data" "$home/projects/archify"
  printf -- '- archify [local-only] - a project (added 2026-09-01)\n' > "$home/data/projects.md"
  reset
  out=$(HERDR_WS_RC=1 FM_HOME="$home" bash "$LIB" --apply 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "reconcile ran against a listing it could not read: $out"
  assert_no_grep "workspace create" "$CALLS" \
    "reconcile created a workspace for a project whose workspace it could not see"
  pass "reconcile: refuses an unreadable fleet rather than duplicating every workspace"
}

test_the_reader_separates_cannot_ask_from_no_match
test_a_payload_that_is_not_a_listing_is_refused_though_it_exits_zero
test_a_truncated_record_invalidates_the_listing
test_an_empty_but_well_formed_listing_is_read_as_empty
test_an_unreadable_listing_never_creates_a_workspace
test_a_genuinely_absent_workspace_is_still_created
test_the_override_path_fails_closed_too
test_existence_reads_the_id_out_of_a_record
test_reconcile_refuses_an_unreadable_fleet
