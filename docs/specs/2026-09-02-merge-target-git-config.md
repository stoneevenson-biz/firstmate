# The merge target is read through a configuration, and the configuration is not the caller's

Status: implemented, 2026-09-02; the HOME pin added 2026-09-03 after the foreign lens rejected the first version.
Gate: `gate-t2-merge-git-config-substitution`.
Implementation: `fm_merge_target_git` and `fm_merge_target_git_config_env` in `bin/fm-merge-target-lib.sh`, refused at `bin/fm-merge-pr.sh`.
Extends: `docs/specs/2026-08-31-merge-target-pin.md`, which this does not restate.

## The defect

`fm_merge_target_git` routes every git read in the merge-target path through a scrub, and says why:

> `git -C <dir>` is not the last word on which repository git reads. `GIT_DIR` in the environment overrides discovery entirely […] That is a merge-target redirect that appears in no argument: the resolution and the origin proof would both read the attacker's clone, agree with each other perfectly, and pin a merge to a repository the caller never saw.

It scrubbed the **GIT_DIR family only**.
`git grep GIT_CONFIG -- bin/` over the shipped tree returned nothing at all.

That answers *which repository does git open*.
It does not answer *which configuration does git believe about it* — and a remote URL is configuration.
`url.<other>.insteadOf` rewrites a URL as git hands it back, so in a clone whose `origin` is the honest repository:

```
honest:   https://github.com/stoneevenson-biz/firstmate.git
attacked: https://github.com/attacker/evil.git
scrubbed: https://github.com/attacker/evil.git      <-- through the shipped scrub
```

with

```sh
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0='url.https://github.com/attacker/evil.git.insteadOf' \
GIT_CONFIG_VALUE_0='https://github.com/stoneevenson-biz/firstmate.git' \
git remote get-url origin
```

The third line is the whole defect: running it through the exact `env -u` list the shipped code used changed nothing.
`git ls-remote --get-url` is rewritten identically.

So the resolution in `fm-merge-target-lib.sh` **and** the independent origin proof in `bin/fm-merge-pr.sh` both read the substituted value and **agree with each other perfectly** — which is precisely the failure the scrub's own header says it exists to defeat.
Two checks, one substituted input, no disagreement to notice.

This shipped. It was found by PR 18's foreign lens, whose reject was recorded as evidence and never read, and PR 18 merged carrying it.

## Two traps

**The obvious payload does not work.**
A direct `remote.origin.url` override through the same mechanism has no effect — repository config wins.
A fix built by guessing which keys are dangerous therefore tests the vector that cannot work, watches it fail, and ships with `insteadOf` (and `pushInsteadOf`) still open.
The gate asserts this explicitly, so a later reader cannot re-derive the wrong lesson.

**No list of names can cover the family.**
`GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` are unbounded in `<n>`, and `env -u` takes no globs.
An enumeration is a promise to have imagined every index; the family is infinite, so the promise cannot be kept.

## The rule

**A merge-target read sees the repository's own configuration and nothing else.**
Three properties, and the second and third are not substitutes for each other.

### 1. Sweep the family by prefix, over the real environment

`fm_merge_target_git_config_env` enumerates every `GIT_CONFIG*` variable the shell can actually see, by prefix, and `fm_merge_target_git` unsets each one it finds.
Nothing is compared against a list, so a name nobody has thought of yet is covered by construction.
The existing GIT_DIR-family scrub is unchanged; this is an addition to it.

### 2. Pin `HOME` itself, not the lookup it feeds

`HOME` and `XDG_CONFIG_HOME` choose which file the global config is read from, and an `insteadOf` in that file substitutes the URL exactly as the variables do — verified the same way, and a bypass of equal power.

**Disabling the lookup is not enough, and the first version of this fix got that wrong.**
It pinned `GIT_CONFIG_GLOBAL=/dev/null`, which stops git *going looking* for a global config — and does nothing about a `~` inside a path the **repository's own** config names.
`include.path = ~/.gitconfig` is an ordinary thing for a clone to carry, repository config is trusted on this path by design, and that `~` expands through `HOME`.
So an attacker holding only the environment got the same `url.<attacker>.insteadOf` back through a file this path still trusts, and the resolution and the origin proof agreed on it exactly as before:

```
honest:                 https://github.com/stoneevenson-biz/firstmate.git
hostile HOME (raw git): https://github.com/attacker/evil.git
through the first fix:  https://github.com/attacker/evil.git
```

That was caught by the foreign lens on the pull request that introduced it, and reproduced before being fixed.

So `HOME` and `XDG_CONFIG_HOME` are pinned at a path that cannot hold anything: `/dev/null` is a character device, so nothing can ever exist beneath it, and `~` resolves to a file git silently skips.
That is a stronger guarantee than a directory we create and hope stays empty, and it needs no scratch state — which is what keeps the "pure and side-effect free" claim intact.

**On git versions, claimed no wider than what was tested.**
`GIT_CONFIG_NOSYSTEM` is ancient; `GIT_CONFIG_SYSTEM` and `GIT_CONFIG_GLOBAL` arrived in git 2.32.
An earlier draft called the three "redundant across git versions" while the global file stayed live below 2.32 — a known bypass described as belt and braces.

What is actually established, on the git this repository is tested with: **the fix does not depend on the two 2.32-only pins.** Removing them leaves the case green; removing the `HOME` pin turns it red. That is a statement about which line of this code does the work, and it is the one the gate proves.
It is *not* a test on an older git, and the previous draft equating the two experiments was wrong to. The reason to expect it to hold there is narrower and worth stating plainly: `~` expansion through `HOME` is not a 2.32 feature. That is a reason, not a result — no pre-2.32 git was run.

`HOME` is **neutralised, never refused on**, unlike the `GIT_CONFIG` family — every environment has one, and refusing on it would refuse every merge.

Nothing the merge-target path reads — `rev-parse --is-inside-work-tree`, `remote`, `remote get-url` — needs global or system config, so this loses nothing.
It does mean a global `insteadOf` a human genuinely relies on is not applied here: that is correct, because the merge target must be the URL the repository actually records, not a rewrite of it.
The one thing dropped with it is `safe.directory`, which git accepts only from global and system config.
A repository that needed it now fails the read, which surfaces as `NOTAGIT` and refuses — a failure, never a wrong merge.

### 3. Refuse, do not merely neutralise

Neutralising alone would leave the merge proceeding quietly on the honest answer.
Something injecting git configuration into a merge path is hostile or badly broken, and reading the right value anyway is not a reason to continue.

The two halves are split by who is asking:

- **The library neutralises.** `fm_merge_target` stays pure and side-effect free, so a caller may ask what a merge *would* target in a hostile environment and get the honest answer. The resolved target is unchanged by any injection.
- **`bin/fm-merge-pr.sh` refuses**, on its own named rail `REFUSED[env/git-config-injected]`, naming the variables it found so the caller can clean the environment. It refuses before anything else runs — before argument parsing, before the passthrough allowlist — because a substituted configuration poisons every read that would follow.

**Why this is not the treatment `GH_REPO` and `GIT_DIR` get.**
Those are pinned and scrubbed but never refused on, and that asymmetry is deliberate: ordinary tooling sets them for ordinary reasons — a git hook exports `GIT_DIR` to every command it runs — so refusing on them would refuse ordinary merges.
Nothing sets `GIT_CONFIG_COUNT` by accident.
Its only purpose is to substitute configuration, so its presence in a merge path *is* the finding.

`HOME` sits on the other side of that line for the same reason: it is neutralised, never refused on, because every environment has one.

## The threat model, stated rather than implied

Two successive claims here were too wide, and both were caught by review rather than by me. The first said the read was hermetic with respect to git configuration while `include.path = ~/.gitconfig` still reached a hostile `HOME`. The second said **no environment variable** could redirect the target — and `PATH` can:

```
$ PATH=<dir with a fake git>:$PATH  bash -c '. bin/fm-merge-target-lib.sh; fm_merge_target <clone>'
OK	attacker/evil	sole-remote:origin
```

A fake `git` answers every question this path asks, so the resolution and the independent origin proof agree on the attacker's repository exactly as an `insteadOf` would have made them. Reproduced, and now gated as a **boundary** rather than described.

### What is defended

Environment variables that change **git's interpretation of a repository**:

| lever | closed by |
|---|---|
| `GIT_DIR` family — which repository is opened | scrubbed |
| `GIT_CONFIG*` — which configuration is applied, in-line | swept by prefix, and **refused** |
| `HOME`, `XDG_CONFIG_HOME` — which config *files* are reachable, including a `~` inside the repository's own `include.path` | pinned at a path that cannot hold anything |

These share a property that makes them worth a guard: they redirect **data**, with no code execution. A merely misconfigured environment — or one an attacker can influence only partially — produces a merge into the wrong repository, silently, with every cross-check agreeing.

### What is not defended, and why not

Environment that substitutes the **executable** or injects code into it: `PATH`, `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, `GIT_EXEC_PATH`.

This is not a smaller version of the above; it is a strictly larger compromise. An environment that can put a fake `git` on `PATH` can equally replace `bash`, `gh-axi`, or `bin/fm-merge-pr.sh` itself — so **no check running inside this process can be a boundary against it.** Pinning the git executable was considered and not done: resolving it from a fixed list of absolute paths either refuses on machines whose git is legitimately in `/opt/homebrew`, `~/.nix-profile` or a version manager, or silently falls back to `PATH` and closes nothing. Either way it would raise the apparent strength of the claim without changing what it actually rests on, which is the failure mode this spec is now on its third round of.

The boundary is asserted in the gate — a fake `git` on `PATH` *does* redirect the target — so that if the executable is ever pinned, the assertion fails and this section has to be re-read.

### What is deliberately still honoured

The repository's own `.git/config`, including an `include.path` naming an **absolute** path. That is the thing being read; a caller who controls a clone's config controls the clone.

Within the defended set, this covers `bin/fm-merge-pr.sh` end to end: the resolution, the ambiguity report, and the origin proof all go through `fm_merge_target_git`.

Other git reads in `bin/` are outside the merge-target path and are not changed here.
They are reported in the pull request rather than fixed in it, so each is judged on its own decision rather than swept along with this one.
