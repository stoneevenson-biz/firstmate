# The merge target is read through a configuration, and the configuration is not the caller's

Status: implemented, 2026-09-02.
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

### 2. Pin the config *files* away, not only the config *variables*

`HOME` and `XDG_CONFIG_HOME` choose which file the global config is read from, and an `insteadOf` in that file substitutes the URL exactly as the variables do — verified the same way, and a bypass of equal power.
Neither can be scrubbed: git needs a `HOME`, and every environment sets one.
So the read pins `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null` and `GIT_CONFIG_NOSYSTEM=1` instead.

The three pins are deliberately redundant across git versions: `GIT_CONFIG_NOSYSTEM` is ancient, `GIT_CONFIG_SYSTEM` and `GIT_CONFIG_GLOBAL` arrived in git 2.32.
On a git older than 2.32 the file half of this is unavailable; the variable half still holds.

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

## Residual, and where it is closed

`fm_merge_target_git` is now hermetic with respect to git configuration, which covers `bin/fm-merge-pr.sh` end to end: the resolution, the ambiguity report, and the origin proof all go through it.

Other git reads in `bin/` are outside the merge-target path and are not changed here.
They are reported in the pull request rather than fixed in it, so each is judged on its own decision rather than swept along with this one.
