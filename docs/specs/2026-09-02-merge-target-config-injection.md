# The merge target comes from a scope, not from a name

Status: implemented, 2026-09-02.
Gate: `gate-t2-merge-config-injection`.
Implementation: `bin/fm-patch-lib.sh` and `bin/fm-merge-target-lib.sh`.
Predecessors: `docs/specs/2026-08-31-merge-target-pin.md`, `docs/specs/2026-09-02-lens-patch-integrity.md`.

## The defect

`docs/specs/2026-08-31-merge-target-pin.md` established that a merge target must be **named, never inferred**, and `fm_merge_target_git` was the guard: every git read in the resolution path ran with the git environment scrubbed, so `GIT_DIR` could not point the reads at another clone.

The scrub was a **blocklist**, and it named only the `GIT_DIR` family. Reproduced against a clone whose `origin` is honestly this repository:

```sh
$ git -C <clone> remote get-url origin
https://github.com/stoneevenson-biz/firstmate.git          # honest

$ GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=url.https://github.com/attacker/evil.git.insteadOf \
  GIT_CONFIG_VALUE_0=https://github.com/stoneevenson-biz/firstmate.git \
  git -C <clone> remote get-url origin
https://github.com/attacker/evil.git                       # FORGED
```

That is a merge-target redirect appearing in no argument — the exact threat `fm_merge_target_git` exists to defeat — arriving through a door the list left open. Resolution and the origin proof at `bin/fm-merge-pr.sh` would both read the forged value and agree with each other perfectly.

**Scrubbing `GIT_CONFIG*` would have been a false green.** Measured at the same time, two more doors reach the same rewrite, and only one of them is in any `GIT_*` family:

| door | forges the URL |
|---|---|
| `GIT_CONFIG_COUNT` + `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` | yes |
| `GIT_CONFIG_GLOBAL=<attacker file>` | yes |
| `HOME=<attacker dir>` with an `insteadOf` in its `.gitconfig` | yes |
| `GIT_CONFIG_KEY_<n>=remote.origin.url` (direct override) | **no** — repo-local config wins |

The last row matters: an allowlist built by guessing key names would have covered the vector that does not work and missed the one that does. And `HOME` shows why the shape of the fix cannot be a list of variable names at all. A blocklist here is a promise to have imagined every variable that can reach git's config, and that promise cannot be kept.

A fourth door needs no rewrite: a `[remote "phantom"]` section in a global or injected config is reported by `git remote` as though the clone had it. That turns a clone with one honest remote into an ambiguous one, or hands a remote-less clone a sole remote to resolve to.

## The rule

**The URL is read from a scope, not from an environment.**

`git config --local` reads this clone's own `.git/config` and nothing else — no system, no global, no `GIT_CONFIG_*`, no `HOME` — and, being `config` rather than `remote`, it is not subject to `insteadOf` rewriting at all. Both properties were measured against the reproduction above; all four doors return the honest URL.

It is also the more honest answer to the question actually being asked. "Which repository is this clone OF" is a property of the clone, and the configured URL is what the clone says it is. A rewrite is a transport preference, and a legitimate one (`ssh insteadOf https`) never changes owner/name anyway.

Two new readers own it, and every call site in `bin/fm-merge-target-lib.sh` and `bin/fm-merge-pr.sh` goes through them:

- `fm_merge_target_remote_url <repo-dir> <remote-name>` — that remote's configured URL.
- `fm_merge_target_remote_names <repo-dir>` — the remotes this clone configures, sorted. Not `git remote`, which reports globally-configured phantoms.

`fm_merge_target_git` keeps its scrub and gains the whole `GIT_CONFIG*` family as defence in depth, for the reads that are not URL reads (`rev-parse`). Because `GIT_CONFIG_KEY_<n>` is unbounded in `n`, the family cannot be written as a fixed `-u` list; the names are discovered from `compgen -e`, which yields **names only** — parsing `env` output would let a newline inside some other variable's value forge an entry.

## The same defect, twice more, in the lens patch

The foreign lens that found the above read the shipped `bin/fm-patch-lib.sh` at the same time and found the identical class — *a value read from something that did not name it* — in code shipped one day earlier by `docs/specs/2026-09-02-lens-patch-integrity.md`. Both reproduced; neither theorised.

**A forged lens base.** `fm_patch_diff_base` accepted any `refs/remotes/<anything>/<default>` as a candidate. A ref under `refs/remotes/` is not evidence that a remote exists; it is just a ref, and **the crewmate whose work is under review can write one.** In a repo with no configured remotes at all:

```sh
git update-ref refs/remotes/fake/main "$(git rev-parse HEAD^)"
```

moved the base one commit forward, and the patch handed to the lens dropped a commit and a file of the branch's own work while remaining a perfectly valid patch. That is the review artifact lying about what the branch changed — the failure the byte truncation caused, reached by a different door, and this one is reachable by the author of the code under review.

A remote-tracking candidate now counts only when its remote is one this clone **configures**, read from local config by `fm_patch_configured_remotes`. `refs/heads/<default>` needs no such proof: it is the clone's own branch, not a claim about a remote.

**A bound that was not a bound.** `fm_patch_build` budgeted only the diff **bodies**, then prepended a header carrying one line per commit and one line per omitted path — both unbounded. Measured: a 900-file branch under a 2000-byte bound produced an **81,411-byte** payload, forty times the number it claimed, every byte of it header. The lens's context is the thing the bound exists to protect, so the header counts.

The budget is now split before anything is written — a quarter to the header, the rest to the bodies — and the header stops adding lines when its share runs out, saying how many it elided. The split is fixed rather than clever: the header cannot spend what the bodies leave over, which wastes a little and is obviously terminating, where a negotiation between the two is neither. A finished payload that still exceeds the bound is a build **failure**, so *a successful build never exceeds `max`* holds without qualification.

## Gates

| gate | asserts |
|---|---|
| `gate-t2-merge-config-injection` | each of `GIT_CONFIG_KEY_<n>`, `GIT_CONFIG_GLOBAL` and `HOME` is confirmed as a live control against real git, then proved not to change the origin proof; a remote declared only in global config is not listed as this clone's; and an end-to-end merge under all three at once lands in origin with the forged repository reaching the merge tool through none of them |
| `gate-t4-lens-patch-base-from-configured-remotes` | a forged `refs/remotes/<name>/<default>` whose remote this clone does not configure leaves the base where it was, and both of the branch's own commits still reach the lens |
| `gate-t4-lens-patch-bound-covers-payload` | a 300-file branch under a 2000-byte bound writes at most 2000 bytes and says how many header lines it elided; at the default bound the payload is still under it and still a valid patch |

The first lives in `tests/fm-merge-t2-vectors.test.sh`, whose design is one gate per door the merge target can be influenced through — which is exactly what this is, and why it belongs there rather than in a suite of its own. The other two are cases in `tests/fm-quarterdeck-t4-lens-patch.test.sh`.

Every case confirms its door as a **control against real git first**. A guard against a redirect that does not happen proves nothing, and this is precisely where the first attempt at a fix went wrong.
