# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain problems, optional capability facts, and primary-checkout `TANGLE:` problems; locally sync live secondmate homes; refresh clones best-effort; install tools only after consent |
| `fm-boot-context.sh`     | Strictly read-only `SessionStart` boot-context emitter: fleet identity for every session, steering detail only for the session that holds the lock, under a hard wall-clock budget |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home, carrying each item's `data/<key>/` dir with it and retargeting the brief's pinned channel - status command and a scout's absolute report path - at the destination home; a re-run fully migrates an item routed before that travelled |
| `fm-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate` |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing watcher needs a prominent banner |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-intake.sh`           | The Wardroom gate between a filled ship brief and its spawn: foreign deep lens, then two thinker lenses under a severity bar where only a blocking defect holds the spawn and everything else rides along as a note; records `proceed:`/`revise:`/`escalate:` in `state/<id>.intake` and warns when its own proceed rate is structurally zero |
| `fm-intake-lib.sh`       | Shared intake channel grammar, strict PANEL verdict parsing, template-echo detection, and the `fm_intake_require_proceed` gate that `fm-spawn.sh` consumes |
| `fm-preflight-lib.sh`    | The structural half of the Wardroom, ahead of the council and of any spawn side effect: refuses a brief naming work the crewmate cannot do - a gitignored path, an unsanctioned primary-checkout path, an invocation of a pool-leasing script, or the retired `>>` status redirect - naming the offender; also a CLI (`bash bin/fm-preflight-lib.sh <brief> [<project-dir>] [<id>]`, exit 0 clean, 1 offending) |
| `fm-verify.sh`           | The Quarterdeck gate between a crewmate's `done:` claim and firstmate's acceptance: adjudicates the worktree's gate ledger structurally ahead of both models, then the foreign lens over the diff, then a fresh-context default-REJECT verifier; records `approve:`/`reject:`/`escalate:`/`lens:` in `state/<id>.verdict`, which `fm-merge-local.sh` and `fm-pr-check.sh` require |
| `fm-gates-lib.sh`        | The one implementation of "is this gate's state acceptable?": a pure read of `gates/ledger.json` and `gates/accepted-red.md` shared by `tests/run-all.sh` and `fm-verify.sh`; also a CLI (`bash bin/fm-gates-lib.sh <root>`, exit 0 acceptable, 1 not, 2 cannot tell) |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`, as a `<project>-<work>` herdr tab in that project's workspace (`--name <work>` chooses the work half); stops and escalates when no herdr server is reachable; ship/scout spawns require an isolated treehouse worktree; secondmate spawns locally sync the home before launch |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-merge-pr.sh`         | Merge a PR-based ship task's pull request into a repository that was NAMED: resolves the target with `fm-merge-target-lib.sh`, proves it equals this clone's `origin` (or takes `--allow-non-origin`), and passes `--repo <owner/name>` to `gh-axi` with `GH_REPO`/`GH_HOST` pinned; passthrough after `--` is an allowlist of long options, a repeated or conflicting target flag refuses, the finished argv is re-read before exec, every refusal names its rail as `REFUSED[<rail>]`, and `--dry-run` prints the pinned command |
| `fm-merge-target-lib.sh` | The one implementation of "which GitHub repository does this merge land in?": `--repo`, then `--remote`, then a full PR url, then a sole remote, and `AMBIGUOUS` for anything else; also owns the PR-reference parse (one walk, both answers, a named reason per rail), the passthrough allowlist, the argv egress assertion, and `fm_merge_target_git`, which scrubs `GIT_DIR` and friends so `git -C <dir>` really means that directory. Pure, never invokes gh/gh-axi; pattern matching pinned to `LC_ALL=C`. Also a CLI (`bash bin/fm-merge-target-lib.sh <dir> [pr] [owner/name] [remote]`, exit 0 resolved, 1 refused, 2 cannot inspect) |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line. Senses staleness on the surface each `state/<id>.meta` records - `agent_status` from one `herdr api snapshot` per cycle, or the pre-cutover pane-text hash for a draining tmux window |
| `fm-sense-lib.sh`        | What supervision senses, split out of the watcher loop so it can be sourced and tested: the one-call herdr agent-state read, what `unknown` means, and `fm_sense_awaiting_verdict` - the state that keeps a crewmate waiting on its Quarterdeck verdict from being reported as wedged |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls and no-fetch local secondmate syncs         |
| `fm-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and teardown                                            |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `fm-send.sh`             | Send one line (or `--key Escape`) to a crewmate pane through acknowledged `herdr agent prompt --wait` delivery; refuses a pane at an approval dialog or with no agent, and reports an unacknowledged steer as unconfirmed rather than re-sending it. The no-agent refusal is deliberate - a shell pane would RUN the steer - so relaunch an exited agent with `herdr pane run <pane-id> '<launch command>'` instead (see the `stuck-crewmate-recovery` skill). Pre-cutover panes keep the verified type-then-retry submit, which exits non-zero when Enter is positively swallowed and pauses `FM_SEND_SETTLE` seconds after success |
| `fm-herdr.sh`            | The herdr surface: library plus CLI (`doctrine` prints the rules rendered from the constants that enforce them; no arguments plans the missing workspaces and `--apply` creates them; `--name <pane> <project> <work>` plans a rename and `--apply` performs it, both slots or neither). Workspace resolution that fails closed on an unreadable listing, `<project>-<work>` pane naming, tab/pane verbs, acknowledged `agent prompt --wait` delivery, and the escalation when no herdr server is reachable. Not named `herdr`, which would shadow the real binary |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry. RETIRED for new use: nothing spawns onto tmux. Still sourced by the away-mode daemon and context-watch, and by `fm-send.sh` for panes that predate the herdr cutover; delete it only once no meta lacks `mux=herdr` |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane, read through herdr, or over tmux for a pane predating the cutover; a failed read says so instead of looking like a quiet crewmate |
| `fm-status.sh`           | Append one crewmate status line to a home's status file; briefs teach this verb because a shell redirect into the firstmate tree is refused as an edit |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return the worktree or retire/release a secondmate home and close its pane on the surface that created it, warning rather than staying silent when a pane could not be closed and keeping the task record at `state/<id>.orphan-pane` so that leftover pane stays findable (and clearing that record once a run does close the pane); protects ship work, requires scout reports, checks child work, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate harness                                                  |
| `fm-lock.sh`             | Per-home firstmate session lock - the helm. Acquire, `status`, and `--take`, which evicts a holder only when it is provably dead; the compare-and-swap is serialised by `fm_lock_try_acquire` on `state/.lock.acquire` |
| `fm-lock-lib.sh`         | The helm check itself: harness-pid resolution, holder liveness, and `fm_lock_require_helm`, the writer-only seam the drive verbs consult. Side-effect free, so `fm-lock.sh status` stays read-only for the boot emitter |

## The helm: which verbs gate on the session lock

Spec: `docs/specs/2026-08-27-n-concurrent-firstmates.md`, section 4.

**The lock guards mutation, not activation.** A second firstmate session on the same
home activates fully - same fleet view, answers "what is the fleet doing", reads any
project, reasons, drafts. It is an observer, not an error. It is refused only when it
asks to spawn, steer, tear down or merge, and only at the moment it asks. Several
sessions on one home is the NORMAL case, so there is no banner, no red text and no
error string at boot: anything that read as an error there would fire constantly and
train the captain to ignore it.

The refusal is one plain captain-facing sentence, carried on stderr by every gated
verb:

> Another session is steering this home right now, so I'm reading rather than driving.
> Say the word if you want me to take the helm.

**The escape hatch is `bin/fm-lock.sh --take`**, permitted only when the holder is
provably dead. There is deliberately no force-evict flag and no env bypass: evicting a
live session means ending that session, which is the captain's action and not
something a script may do on its own.

### The gated seven

Each calls `fm_lock_require_helm "$STATE" <label> || exit 1` before it mutates
anything. `gate-c1-helm-writer-only` pins this roster exactly, so adding or removing
one is a reviewed change, not a drift.

| verb | what it drives |
| --- | --- |
| `fm-spawn.sh` | spawn - creates the pane, the worktree and the meta |
| `fm-send.sh` | steer - puts a line into a live crewmate's composer |
| `fm-teardown.sh` | teardown - returns the worktree or retires a secondmate home |
| `fm-merge-local.sh` | merge - fast-forwards a project's local default branch |
| `fm-pr-check.sh` | the merge path - records `pr=` and arms the merge poll |
| `fm-promote.sh` | re-contracts a live task by rewriting its meta |
| `fm-update.sh` | fast-forwards this home's instructions and every secondmate's |

### What does not gate, and why

- **Every boot path.** `fm-bootstrap.sh`, `fm-boot-context.sh`,
  `fm-captain-bootstrap.sh`, `fm-guard.sh` and `fm-wake-drain.sh` run at session start,
  so a refusal there would be exactly the boot-time refusal section 4 rules out.
  `fm-bootstrap.sh install <tools...>` is a separate invocation with different
  semantics and it does not gate either: besides running at boot like the rest of
  bootstrap, what it mutates is the machine's tool inventory - homebrew, npm - not this
  home's fleet state, and it is idempotent and captain-authorised in the session that
  asks for it. Blocking it would stop an observer from fixing a missing tool, which
  helps nobody.
- **`fm-guard.sh` specifically.** It always exits 0 by design - it warns, it never
  blocks - so it is the wrong place to enforce anything, and a gate that could not
  stop a caller would be theatre.
- **`fm-fleet-sync.sh`.** Called from bootstrap (a boot path) and from
  `fm-teardown.sh` (already gated). Fetch and clean fast-forward only, and idempotent.
- **Observation.** `fm-peek.sh`, `fm-status.sh`, `fm-review-diff.sh`, `fm-watch.sh`,
  `fm-watch-arm.sh`, `fm-harness.sh`, `fm-project-mode.sh` read, report, or append the
  append-only records any session may write.
- **`fm-verify.sh` and `fm-intake.sh`.** They record decisions in append-only channels,
  which is reasoning and drafting - exactly what an observer may do. They cannot act on
  those decisions: every verb that consumes one (`fm-spawn.sh`, `fm-merge-local.sh`,
  `fm-pr-check.sh`) is gated. Same for `fm-brief.sh`, which drafts.
- **Libraries.** `fm-herdr.sh`, `fm-ff-lib.sh`, `fm-tmux-lib.sh`, `fm-wake-lib.sh` and
  the decision-channel libs are sourced by the entry points above. The gate belongs at
  the entry point so the refusal can name the verb the captain actually asked for.
- **Deferred, and named rather than dismissed.** `fm-home-seed.sh` and
  `fm-backlog-handoff.sh` are genuine writers - they lease or retire a secondmate home
  and move backlog items between homes - but they belong to the secondmate-provisioning
  chain, which is a separate task's scope. `fm-context-watch.sh` and
  `fm-compact-crewmate.sh` steer a pane, but only when fired by the watcher the
  steering session armed; gating a watchdog mid-checkpoint would strand a handoff.
  `fm-wake-drain.sh` destructively consumes the shared wake queue, which two sessions
  can race for - but it runs on the recovery path at session start, so gating it would
  be a boot-time refusal by another name. That race predates this seam.

### Two edge policies

- **harness-not-found.** `fm_lock_harness_pid` can fail to identify a harness at all -
  an unverified adapter, a wrapper, a shell outside any agent. The seam then **fails
  open, out loud** on stderr. Failing closed would be a lock-out by another route: such
  a session could never prove it is the holder, so it could never drive, and `--take`
  would not help because the fault is not with the holder.
- **Atomicity.** Acquire is a compare-and-swap - read the holder, judge it, write ours -
  and two sessions racing must not both conclude they hold the helm. `fm-lock.sh` holds
  `fm_lock_try_acquire` (`bin/fm-wake-lib.sh`) on `state/.lock.acquire` across the whole
  critical section. That primitive is this repo's existing atomic mutex - an atomic
  `ln -s` create, with dead-owner reclamation itself serialised through a second lock -
  and `tests/fm-watcher-lock.test.sh` already proves it single-winner under 40-way
  concurrency. A second CAS implementation would be a second thing to get wrong.

### Secondmates

`fm-lock.sh` is per-home (`STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"`), and every
secondmate home runs these same scripts with its own `FM_HOME`. A secondmate is
therefore never refused because the main firstmate holds the main home's lock;
`gate-c2-helm-take-and-isolation` proves it positively, by having a secondmate drive a
real mutation through while the main home stays held.
