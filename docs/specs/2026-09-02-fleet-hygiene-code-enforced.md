# Fleet hygiene is code, not memory

Status: implemented, 2026-09-02.
Gates: `gate-t4-state-residue`, `gate-t4-restart-scope`, `gate-t4-squash-landed`.
Implementation: `bin/fm-state-lib.sh` (new), `bin/fm-teardown.sh`, `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh`.

Three defects, all observed on the captain's home, all of the same shape: a rule
that was written down somewhere and enforced nowhere.

## 1. Teardown left state debris

### The defect

`bin/fm-teardown.sh` removed the pane, the worktree, and the seven state files it
knew by name. It left behind every marker `bin/fm-watch.sh` had minted for that
task: `.seen-<id>_status`, `.seen-<id>_turn-ended`, and the per-pane
`.hash-<key>` / `.count-<key>` / `.stale-<key>` trio.

Measured 2026-09-02: **195 entries in `state/`, of which 9 belonged to live
work.** Names of tasks finished in June are still there.

The cause is structural rather than careless. The code that CREATES those names
and the code that ENDS the task each knew half the naming rule, and neither knew
the other's half. `fm-watch.sh` computed `key=$(printf '%s' "$w" | tr ':/.' '___')`
inline; `fm-teardown.sh` hand-listed seven `rm -f` paths. Nothing connected them,
so nothing could keep them in step.

It is not only untidy. **Every one of those names is a suppressor.** `.seen-*`
means "this signal was already reported"; `.stale-*` means "this exact stalled
state was already reported". A task id that comes back around, or a pooled pane
id that gets reused, inherits a marker that silences its first real wake. The
residue is a supervision hazard with a long fuse.

### The rule

**Which state files belong to a task has one implementation**, `bin/fm-state-lib.sh`.
`fm-watch.sh` mints marker names through `fm_state_key` and
`fm_state_seen_marker`; `fm-teardown.sh` removes them through
`fm_state_prune_task`. Neither restates the rule, so they cannot drift again.

One file survives a prune: `<id>.orphan-pane`, and only on a close that failed,
because it is then the only durable record naming the leftover pane. That is why
the prune takes a keep list rather than being a wildcard.

`fm_state_task_residue` is deliberately **not** built from the same list. It
SCANS the state dir for anything still named after the task, so a state file
added to the fleet tomorrow and forgotten in the prune list is caught rather than
accumulating. Teardown reports its own residue as a warning, so the invariant is
self-checking in production and not only under test.

### Gate

`gate-t4-state-residue` (`tests/fm-teardown-t4-state-residue.test.sh`) mints the
markers by **running the real watcher**, so what teardown must remove is whatever
`fm-watch.sh` actually creates rather than what a test guessed. It then asserts
the scan finds nothing, that a failed close keeps the orphan record and nothing
else, and that `fm_state_key` and `fm_ctx_sanitize_key` still give one answer.

## 2. `--restart` did not match its documented contract

### The defect

`bin/fm-watch-arm.sh --restart` is documented to stop only THIS home's watcher,
via the pid in this home's `state/.watch.lock`, and never to become the
`pkill -f bin/fm-watch.sh` that would reach every firstmate home on the machine -
every secondmate runs the same script.

The evidence it relies on was written best-effort:

```sh
printf '%s\n' "$FM_HOME"    > "$WATCH_LOCK/fm-home"     || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
```

The lock files were observed **zero-length while a watcher ran**. With no record,
the restart can prove nothing about the live pid it finds. It declines to signal
it - which is the safe direction and correct - and then forks a replacement that
cannot take the still-held lock either, so the home is left with a watcher it can
neither use nor replace, behind a `watcher: FAILED` line that says nothing about
why.

### The rule

**A watcher that cannot be identified does not run.** `fm_watch_lock_record_identity`
writes the record and reads it back; `fm-watch.sh` refuses to start if it cannot
complete it. A watcher nobody can identify is a watcher nobody can stop.

**A kill needs positive proof.** `fm_watch_lock_classify` reads the lock once and
answers with exactly one word, and both callers act on that one reading:

| answer | meaning | what `--restart` does |
|---|---|---|
| `none` | nothing holds the lock | start a watcher |
| `ours-live` | live pid; home, watcher path and pid identity all match | TERM it, wait, replace it |
| `stale` | dead pid, or a live pid the complete record contradicts (a reused pid) | clear the record, replace it. Signals nothing |
| `foreign` | live pid whose record names another home or watcher | REFUSE, loudly. Signals nothing |
| `unidentified` | live pid behind an incomplete record | REFUSE, loudly. Signals nothing |

The two refusals are the change in behaviour: previously an unprovable live lock
produced a doomed fork and a generic failure line. Now nothing is signalled,
nothing is forked, and the message names the pid and what is missing.

Note that `stale` covers a LIVE pid whose identity the record contradicts. That
is a reused pid, and the record proves it is not the watcher, so clearing is
right and killing would be wrong - the pre-existing behaviour, now stated once.

### Gate

`gate-t4-restart-scope` (`tests/fm-watch-t4-restart-scope.test.sh`) runs two real
watchers in two real homes and restarts one, asserting that home B's watcher is
still alive and its lock byte-for-byte unchanged. Scoping is proven against a
second home, not asserted about one.

## 3. Teardown refused after a squash merge

### The defect

The highest-value of the three, because it is the difference between hygiene
being automatic and the pool silently filling until dispatch fails.

The safety check asks one question: is `HEAD` reachable from any remote-tracking
branch?

```sh
unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- | head -5)
```

Squash-merging a PR with `--delete-branch` answers **no** for work that is
completely landed. The merge replays the whole branch as ONE new commit on the
default branch and deletes the branch, so not one of the branch's own commits is
reachable from any remote ever again.

Observed 2026-09-02: six merged worktrees all refused with *"has work not on any
remote"*. The treehouse pool reached **zero available slots** and the next
dispatch died with `treehouse get did not enter a worktree within 60s`.

The check was right in intent and wrong for the commonest merge button in the
fleet.

### The rule

**Prove it, and refuse when you cannot.** The check is not relaxed into "assume
landed". The content is proven to be on the default branch using the only
evidence a squash leaves behind - the patch itself:

1. Take the branch's fork point from the default branch (its merge-base).
2. Synthesise the commit a squash WOULD produce: the branch's tree, parented on
   that fork point. Its diff is exactly the diff the merge applied.
3. Ask `git cherry` whether an equivalent patch is already on the default branch.
   That compares patch-ids, which are independent of commit id, author, message
   and line numbers - so the squash commit matches while an unrelated commit does
   not.

Anything short of a patch-id match refuses. A rebase that changed the content, a
conflict resolved differently, a branch that was never merged, and a merge into a
different repository all fail to prove it. **Uncommitted changes are never
eligible**: no merge can have landed a diff that exists only in a working tree.

Two details that decide whether the proof is usable:

- **The base must be the authoritative one.** A pooled clone's local default is
  frozen at clone time and can never contain the merge, so PR-mode tasks prove
  against `origin/<default>`; a `local-only` task proves against the local
  default, which is what `bin/fm-merge-local.sh` writes.
- **The base must be current.** The merge that landed this work is usually newer
  than the last fetch, so a failed proof refreshes the remote-tracking ref once
  and retries. Concluding "not landed" from a ref that predates the answer is the
  same false refusal by another route.

Scope is unchanged in every other respect: the dirty check, the fork-counts-as-a-
remote rule, the scout carve-out, and `--force` all behave exactly as before.

### Gate

`gate-t4-squash-landed` (`tests/fm-teardown-t4-squash-landed.test.sh`) pins both
halves in one file so neither can be "fixed" by breaking the other: a
squash-merged-and-deleted branch over a deliberately stale ref IS torn down, and
genuinely unpushed work, differently-squashed content, and a dirty worktree are
all STILL refused.
