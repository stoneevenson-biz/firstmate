# A routed item takes its reporting channel with it

Status: built. Gates `gate-t4-routed-brief-reports-to-destination`,
`gate-t4-handoff-safety-preserved`.
Implementation: `bin/fm-backlog-handoff.sh`.

## The evidence

`fmx-boot-e3` was routed to the `fmx-plat` secondmate.
Its brief still pointed the crewmate at the **main** home's `state/<id>.status`.

Two consequences, both real.

1. **The owning supervisor mirrored a channel it did not own.**
   The secondmate was responsible for the task, but the reports landed in the main home's state dir, where the secondmate's own scoped watcher is not looking.
2. **Both homes carried a record for one task**, so reconciliation saw it twice and neither home was authoritative.

## Why the pin exists, and why that is what broke

The reporting command in a brief is not inherited from the environment.
`bin/fm-brief.sh` pins the home into it:

```
FM_HOME='<home>' FM_STATE_OVERRIDE='<home>/state' bash '<home>/bin/fm-status.sh' '<id>' "<state>: ..."
```

That pin is deliberate and it is load-bearing.
`fm-status.sh` resolves its state dir from `FM_STATE_OVERRIDE`, then `FM_HOME`, and a secondmate runs under `FM_HOME=<its own home>`, so an *unpinned* command would divert a charter's escalation into the secondmate's own state dir instead of the main home's file the brief names.
Gate `gate-status-verb` holds that property.

The pin therefore does exactly one thing: it makes the command reach the home that **generated** the brief.
That is right until the item is routed to a different home, at which point the home that generated the brief is no longer the home that owns the work — and the pin, being a hard-coded absolute path, keeps aiming at the old one.
The defect is not the pin. It is that the pin did not travel.

## What moves

Two things move together, because either alone leaves the destination half-equipped:

- **The backlog line**, as before — verbatim, under the same section heading.
- **The item's `data/<key>/` dir**, so the destination home holds the brief it is expected to dispatch from (`bin/fm-spawn.sh` reads `$FM_HOME/data/<id>/brief.md`), and the origin stops holding a second copy of a task it no longer owns.

Inside the moved brief, every `fm-status.sh` reporting command and every quoted `<key>.status` path is rewritten to name the destination home: its root as `FM_HOME`, its `state` dir as `FM_STATE_OVERRIDE`, and its own `bin/fm-status.sh` when it has one.
A destination without its own copy of the script keeps whatever script path the command already had — the pins are what decide where the line lands, and naming a file the destination does not have would break a command that otherwise works.

**A scout's channel is not its status file — it is the report.**
`bin/fm-brief.sh` pins the deliverable as an absolute path (`Write your findings to <home>/data/<id>/report.md`), and `bin/fm-teardown.sh` reads `$DATA/$ID/report.md` from **its own** home.
So a report path left pointing at the origin is the same defect as a status path left there, with a worse ending: the crewmate writes the findings into a home that no longer owns the task — and which this very handoff has just emptied — the owning secondmate never sees the deliverable, and its teardown then *refuses*, because the report it looks for was never written where it looks.
Absolute `<key>/report.md` paths are therefore retargeted alongside the status paths.
A *relative* `data/<key>/report.md` is left alone: it resolves correctly in whichever home reads it, so rewriting it would only add risk.

## Three decisions worth stating

**The rewrite is a normalisation, not a diff.**
Every reporting command in the destination brief is rewritten to the destination home *whatever it said before*, and this runs for every requested key — including one already present in the destination backlog, which the mechanical move itself skips.
So **re-running the handoff is the repair path** for an item routed before this existed: `bin/fm-backlog-handoff.sh <secondmate-id> <item-key>` converges it in place instead of reporting "already present" and leaving the misroute.
The alternative — repairing only items that happen to move today — would have left every previously routed item silently broken, discoverable one lost report at a time.

The repair is a **full migration**, not just a rewrite.
The state the pre-fix code actually produced is: line in the destination backlog, `data/<key>/` still in the origin — because the old code moved lines and nothing else.
So that path has a dir to carry over and an origin copy to drop, exactly like the moving path, and it reports what it did.
A repair that copied the dir but left the original would swap one half of the defect for the other: instead of one home owning the task and another owning the channel, both homes would hold a copy and neither would be authoritative — the same duplicate-ownership failure, now created by the fix.

**The rewrite is narrow on purpose.**
It touches the `fm-status.sh` invocation and quoted `<key>.status` paths, and nothing else.
A blanket substitution of the origin home's path across the brief would also rewrite the *task description* — and a brief that names the origin home for its own reasons is the crewmate's instructions, not a channel.
Corrupting the work to fix the reporting would be a worse defect than the one being fixed.

**It fails loudly rather than half-routing.**
After rewriting, the brief is re-read: every `FM_HOME` pin must name the destination, and every `<key>.status` path must be the destination's.
A brief whose command shape the rewrite could not reach aborts the handoff and rolls back, because a brief that moved while its channel did not is exactly the defect, and a silent half-move is the shape of it that is hardest to notice.
A brief that names no reporting command at all is not an error — it is left unchanged with a note, since the mechanical move is still correct for it.

## What did not change

Every refusal the script already had still refuses, and now has more to protect:

- an `## In flight` item is refused, and its brief does not travel;
- a key matching neither backlog aborts atomically — neither backlog is touched **and** the brief dir is still whole in the origin;
- a destination lacking a matching `.fm-secondmate-home` marker, or with unsafe operational dirs, is refused and is not written into;
- the move stays idempotent: a re-run duplicates no line, and an already-retargeted brief is left byte-identical.

The transaction was widened to cover the files.
The destination copy is made **before** anything is removed from the origin, and the origin's copy is removed only after the destination is whole; a failure anywhere in between rolls back to a state where the item is still entirely in the origin.

One case is deliberately left alone: when **both** homes hold a `data/<key>/` dir, the destination's is the live copy, so it is neither clobbered nor deleted from under whoever wrote it.
The origin's stale copy is **named in the output** rather than removed, because deleting a directory this script did not place there is not a mechanical move.
The destination's own brief is still retargeted — it is the one that will run.

## How it is proven

Not by grepping the brief text.
Asserting the string changed proves the string changed; it does not prove the channel moved.

`gate-t4-routed-brief-reports-to-destination` scaffolds a real brief with the real `bin/fm-brief.sh`, hands the item off, then **exercises the destination brief's own channel**.
For a ship task that means extracting the reporting command and running it; for a scout it means taking the report path the brief names and writing the report to it.
The assertion is where the thing landed: the destination home, and not the origin's.

It runs that proof four ways:

1. an item routed with its brief;
2. an item in the state the pre-fix code actually produced — line already in the destination backlog, dir still in the origin — where the re-run must fully migrate it, leave no copy behind, and say so. A fixture that pre-copied the dir to the destination would model a state the old code could not reach, and would miss exactly the both-homes defect;
3. a destination with no `fm-status.sh` of its own;
4. a routed **scout**, asserting its report lands at `<destination>/data/<key>/report.md` — the exact path the owning home's `bin/fm-teardown.sh` reads — and that nothing is written back into the emptied origin.

`gate-t4-handoff-safety-preserved` holds each pre-existing refusal against the harder case, with a brief dir present in every arm.
