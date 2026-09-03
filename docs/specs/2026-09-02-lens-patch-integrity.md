# The lens patch is a patch

Status: implemented, 2026-09-02.
Gates: `gate-t4-lens-patch-scoped-to-branch`, `gate-t4-lens-patch-file-boundary-split`, `gate-t4-lens-patch-refuses-corrupt`, `gate-t4-lens-patch-keeps-own-tests`.
Implementation: `bin/fm-patch-lib.sh`, consumed by `bin/fm-verify.sh`.

## The defect

The Quarterdeck has two halves.
The independent verifier re-runs the gates in the crewmate's worktree and reads whatever it needs.
The foreign lens reads **only** `data/<id>/lens-diff.patch`.

That file was built like this:

```sh
{ git log --oneline "$BASE..HEAD"; git diff "$BASE..HEAD"; } | head -c 200000 > "$DIFF_FILE"
```

A byte bound applied to a patch cuts it mid-hunk.
The artifact that exposed this is on disk: `data/fmcmd-guard/lens-diff.patch`, 2026-09-02, **exactly 200,000 bytes**, ending mid-AWK-statement.
`git apply --check` answers `corrupt patch at line 3403`.
It carried **7 commits where the branch owned 3**, and it contained **none of the branch's own tests**.

Three separate faults, one artifact:

1. **Scope.** The base was the merge base against a cached `refs/remotes/origin/main` that a failed fetch had left four already-merged commits stale. `resolve_diff_base` preferred the authorisation base and fell back to `refs/heads/<default>` only when that base was absent entirely - so a stale-but-present remote-tracking ref won outright over a local default branch that knew better.
2. **Truncation.** `head -c` does not know what a patch is.
3. **What got dropped.** Truncation by byte drops whatever sorts last, and `tests/` sorts after `bin/` and `docs/`. The reviewer that most needed to see whether the change was proven saw none of the proof.

Why this is severe rather than merely untidy: it does not fail the gate, it silently halves it.
A verdict formed from a corrupt artifact looks exactly like a verdict formed from the real change.
The `fmcmd-guard` lens survived only because it read what it could and said so; a less careful reviewer would have approved a change it had never seen.

## The rule

**Never hand out a patch that is not a valid patch.**
Three properties, in priority order.

### 1. Scope it to the branch's own commits

`fm_patch_diff_base` takes the base that is furthest **forward** among the default-branch-shaped refs - `refs/heads/<default>` and each `refs/remotes/<remote>/<default>` - seeded by `fm-verify`'s authorisation base so the result can only ever tighten the range, never widen it.
Every commit this drops is one that some other default-branch ref already carries, so it was never this branch's to answer for.

This is the opposite of the rule for the **authorisation** base, and deliberately so.
`fm-verify.sh`'s own header withdraws furthest-forward there on security grounds: a pooled clone shares `refs/heads/<default>` with the primary checkout, so an ordinary local commit could launder a self-authored `gates/accepted-red.md` declaration into an inherited one.
That reasoning does not reach the diff payload, which authorises nothing - the same carve-out the existing header already states.

The candidate set is narrow on purpose.
A sibling crewmate branch cut from this one would otherwise be a candidate whose merge base is one of *our* commits, and moving the base onto it would hide our own work from the lens.
A candidate that already contains `HEAD` is skipped, since its merge base is `HEAD` and the patch would be empty.

### 2. Never truncate mid-patch

A bound is spent on whole **files**.
Every file that does not fit is named in the payload header with its reason, under a heading that tells the reviewer plainly that it did not see them.
A reviewer who knows what it did not see can weigh its own verdict; one handed a silent truncation cannot.

Once a bound has to drop something, *which* something is a review decision rather than an accident of path order.
Test material is laid down first and everything else follows in path order, because a reviewer that cannot see the tests cannot judge whether the change is proven - which is the one question the Quarterdeck exists to ask.
Binary files are named, never embedded: their content is worthless to a reviewer, and `Binary files ... differ` is not an appliable patch anyway.

The bound is `FM_LENS_PATCH_MAX_BYTES`, default 200000 - the same number as before, now meaning something different.

### 3. Fail closed

The finished artifact is re-read with `git apply --check`, against a scratch index read from the base tree rather than against the working tree (the worktree is at `HEAD` with the change already applied, and may be dirty besides).
If it does not pass, `fm-verify` **refuses to run the lens** and records `lens: none`, warning on stderr - the loud degrade `bin/fm-lens-lib.sh` already models when no lens is reachable.
The independent verifier is untouched and still runs.

Properties 2 and 3 are belt and braces on purpose.
Splitting on file boundaries is what makes corruption impossible; the apply check is what *proves* it for this particular artifact instead of assuming it.

## What is out of scope

What the lens is asked to do is unchanged, and `FM_LENS_CMD` keeps its semantics: a command that reads the payload on stdin and writes a review on stdout.
The independent verifier is unchanged.
The authorisation base, the gate-ledger adjudication, and the verdict grammar are unchanged.

## Two doors this spec left open

Both were found by a foreign lens reading the shipped implementation on 2026-09-02, both reproduced, and both are fixed and gated under `docs/specs/2026-09-02-merge-target-config-injection.md`, which carries the reasoning:

- **the base was forgeable.** `fm_patch_diff_base` accepted any `refs/remotes/<anything>/<default>`, and the crewmate under review can write one - `git update-ref refs/remotes/fake/main HEAD^` hid a commit and a file of its own work behind a valid patch. A remote-tracking candidate now counts only when this clone configures that remote.
- **the bound covered only the diff bodies.** The header carried one line per commit and one per omitted path, both unbounded: 900 files under a 2000-byte bound wrote 81,411 bytes. The budget is now split before anything is written, and a payload that still exceeds the bound is a build failure.

## Gates

| gate | asserts |
|---|---|
| `gate-t4-lens-patch-scoped-to-branch` | against a fixture with a deliberately noisy base - a stale cached `refs/remotes/origin/<default>` plus an unreachable origin, the pooled-clone shape the defect arrived in - the patch carries the branch's own commit and neither unrelated landing |
| `gate-t4-lens-patch-file-boundary-split` | a diff over the bound drops whole files, names each omission and its reason in the payload, and the artifact still passes `git apply --check`; the file-header count equals the count the header declares |
| `gate-t4-lens-patch-refuses-corrupt` | a patch cut mid-hunk is refused by `fm_patch_check` with a reason, and an unusable payload makes `fm-verify` refuse the lens outright - the lens command is never invoked, `lens: none` is recorded, and the independent verifier still runs |
| `gate-t4-lens-patch-keeps-own-tests` | under a bound that forces omission, the branch's own test file is in the patch and the source file it displaced is named as omitted |

All four live in `tests/fm-quarterdeck-t4-lens-patch.test.sh`, one case each.
One combined "the patch is good" gate would have gone green the moment any single property was fixed, which is exactly the shape that let three of these faults ship inside one artifact.

Red-first evidence, against the code as it stood: a fixture branch whose own commit adds six ~16KB source files and one test file produced a payload of exactly 200,000 bytes, ending `+echo "source file 5 line 33 padding`, which `git apply --check` called `corrupt patch at line 3664`, and which contained zero occurrences of the branch's own test path.
