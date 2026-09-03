#!/usr/bin/env bash
# fm-poll-lib.sh - the one implementation of "what does a merge poll script say?"
#
# THE DEFECT IT EXISTS FOR. bin/fm-pr-check.sh compiles state/<id>.check.sh from
# a crewmate-supplied PR reference, and bin/fm-watch.sh runs that file as
# `timeout N bash <file>` every FM_CHECK_INTERVAL, indefinitely, inside the
# session that holds the helm and merge authority. The first version of that
# writer expanded the reference into a double-quoted word, so a `"` in it became
# shell the watcher executed. See docs/specs/2026-09-02-prcheck-ref-injection.md.
#
# WHY THIS IS A LIBRARY RATHER THAN FOUR LINES IN THE WRITER. The rule it holds -
# every component is serialised with `printf %q` - is the branch's central
# defence, and inline in the writer it was UNTESTABLE: the caller upstream is
# fm_merge_target_parse_pr_ref, which only ever yields a digits-only number and a
# [A-Za-z0-9._/-] slug, so `%q` was never handed anything that needed quoting.
# Both `%q` calls could be deleted and every assertion still passed. A defence
# whose removal no gate can detect is not a defence, so the rule lives here where
# a test can hand it a quote, a space, a separator, a command substitution and a
# newline directly.
#
# `%q` IS BASH'S OWN "quote this so it re-reads as exactly this one word", and
# that is the whole claim: whatever a component contains it lands in the
# generated file as a single word, so no caller byte can become shell even if the
# parser upstream is later loosened. It is NOT a claim about meaning: a component
# reading `-Rowner/other` would be one safely-quoted word that `gh` still takes
# as an attached repo flag, which is fm_merge_target_names_repo's business.
# Independent at the shell layer; never a substitute for the parse.
#
# PURE. It formats strings and prints them. It writes no file, reads no state,
# and invokes nothing - so a caller may ask what a poll WOULD say without arming
# one.
#
# Callers: bin/fm-pr-check.sh. Also a CLI for humans and tests:
#   bash bin/fm-poll-lib.sh <pr-number> <owner/name>
#
# Spec: docs/specs/2026-09-02-prcheck-ref-injection.md

# fm_poll_render <pr-number> <owner/name>: print the poll script, terminal
# newline included. The check contract (AGENTS.md section 7) is that it prints
# one line iff the PR is merged and stays silent otherwise, so the comparison is
# exact and fail-closed; `--repo` is pinned so the poll names the repository it
# asks about rather than leaving `gh` to infer one from whatever clone the
# watcher happens to be standing in.
#
# The format string is a LITERAL - single-quoted, never interpolated - so the
# only things that vary at write time are the two %q-serialised components.
fm_poll_render() {
  # shellcheck disable=SC2016  # the single quotes are the point: nothing in this
  # format expands at write time except the two %s components.
  printf 'state=$(gh pr view %s --repo %s --json state -q .state 2>/dev/null)\n[ "$state" = "MERGED" ] && echo "merged"\n' \
    "$(printf '%q' "${1:-}")" "$(printf '%q' "${2:-}")"
}

# CLI form, for humans and for tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_poll_render "${1:-}" "${2:-}"
fi
