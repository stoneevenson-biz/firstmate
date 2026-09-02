# The merge target is named, never inferred

Status: implemented.
Gates: `gate-t1-merge-target-resolution`, `gate-t1-merge-repo-pinned`, and the ten per-vector gates in [Every door, and a gate on each](#every-door-and-a-gate-on-each).

## The two defects

### 1. The merge target was resolved implicitly

`~/firstmate` carries two GitHub remotes:

| remote | repository | what it is |
| --- | --- | --- |
| `origin` | `stoneevenson-biz/firstmate` | the captain's fork, where the fleet's PRs are raised |
| `upstream` | `kunchenguid/firstmate` | the public project this repo is a template of |

`gh`-shaped tooling does not merge "the repository you are standing in".
It resolves a *base repository* from the clone's remote set, and for pull-request operations in a fork it prefers the parent.
So a command that names no repository is answered by the tool, from the remotes, in favour of the public project.

On 2026-08-29 firstmate ran `gh-axi pr merge 5` in that clone with no repository argument, and it resolved to **upstream**.
It was a no-op only because that PR had already merged, in June.
Had it been open, a stranger's contribution would have been merged into open source under the captain's name, and no step anywhere in the path would have named a repository out loud.

This is not a mistake that announces itself.
The command looks right, the tool exits zero, and the merge lands somewhere nobody named.

### 2. The guard that should have caught it did not fire

The captain's permission profile denies `Bash(gh pr merge*)` — someone deliberately put a rail there.
But `AGENTS.md` requires the fleet to use `gh-axi` for every GitHub operation, and `gh-axi pr merge` does not match the pattern `gh `.

The mandated tool walks straight past the guard.

A rail that silently does not fire is worse than no rail, because everyone downstream assumes it is holding.
The profile is machine-wide and the captain's, so this repo does not edit it; the exact rule is stated in `AGENTS.md` and in the PR that introduced this spec, for the captain to apply.

## The rule

One implementation: `fm_merge_target` in `bin/fm-merge-target-lib.sh`.
Nothing else decides a merge target, and no caller restates the rule.

In precedence order:

| # | input | outcome |
| --- | --- | --- |
| 1 | `--repo <owner/name>` | the caller named the repository. Used verbatim; a malformed slug refuses (`BADREPO`) rather than being cleaned up. |
| 2 | `--remote <name>` | the caller named a remote. Its URL is parsed to `owner/name`. A remote that does not exist, or whose URL is not a GitHub repository, refuses (`BADREMOTE`). |
| 3 | a full PR URL | `https://github.com/<owner>/<repo>/pull/<n>` names its own repository. Nothing about it can be ambiguous, so it is an explicit choice like the two above. |
| 4 | exactly one remote | one candidate is not a choice between candidates. Resolve from its URL. |
| 5 | more than one remote | **`AMBIGUOUS`.** Refuse, naming every remote and the repository it points at. |
| 6 | no remotes | `NOREMOTE`. There is nothing to merge against. |

Two properties of this rule are the whole point, and both are load-bearing:

**The target is always passed.** Even case 4, where there is only one possible answer, resolves `owner/name` from the remote's own URL and hands it to the tool as `--repo`. A tool that is told the repository cannot pick a different one. The unambiguous case is pinned not because it is at risk but because a path that is sometimes pinned is a path whose pinning nobody can rely on.

**Case 5 does not quietly prefer `origin`.** That is the tempting shortcut and it is wrong here: the near-miss happened in a clone that *had* an `origin`, and the tool still chose the other remote. `origin` is a convention, not a statement. Once a second remote exists, a bare PR number exists independently in each of them and nothing in the input says which was meant — so the answer is not "guess the likely one", it is "say which". `--remote origin` is how a caller says origin, and the target is then read from origin's own URL rather than from anything the tool believes.

The rule is **pure**: it reads `git remote` in a directory and parses strings. It never fetches, never writes, and never invokes `gh`, `gh-axi`, or `curl`. A resolver that shelled out to the tool to ask "what would you pick?" would inherit the very inference it exists to replace, and would make *asking* indistinguishable from *merging*. `gate-t1-merge-target-resolution` freezes that with a tripwire.

## The path

`bin/fm-merge-pr.sh <task-id> [<pr-url-or-number>] [flags]` is the fleet's only merge path for a PR-based ship task.

It resolves the project from `state/<id>.meta` (`project=`), the PR from that meta (`pr=`, written by `fm-pr-check.sh`) or from an argument, asks `fm_merge_target` for the repository, and then runs:

```
gh-axi pr merge <n> --repo <owner/name> [passthrough args after --]
```

- A refusal prints a bordered `●` banner naming every candidate remote and the two ways to disambiguate, and **never invokes the merge tool at all**.
- A target that is not this clone's `origin` still merges — an upstream contribution is legitimate, and it was named — but it is announced on stderr, naming the remote it belongs to. That shape is exactly the 2026-08-29 near-miss, so it is never silent.
- `--dry-run` prints the exact pinned command and runs nothing.
- `mode=local-only` tasks are refused here and pointed at `bin/fm-merge-local.sh`, which is their merge path.

**Passthrough may not smuggle a target.** Everything after `--` reaches `gh-axi pr merge`, which is what makes `--squash` and `--delete-branch` available — but a repo flag there is refused outright. `gh-axi` scans every `-R`/`--repo` occurrence and keeps the **last** one, so `-- --repo other/repo` would silently win over the pin, and stderr would still announce the resolved target: the same "lands in a repo nobody named" defect, wearing this script's own advertised feature as a disguise. Refusing at parse time is the fix; trying to win an ordering fight with a CLI whose flag semantics this script does not control is not.

**The number and the repository come from the same validated parse.** A PR reference is either a bare number or a github.com PR URL that `fm_merge_target_from_pr_url` has already accepted; anything else yields no number and the call refuses, before any remote is inspected. Reading a number out of any `*/pull/<digits>` string instead was a fail-open the whole path inherited: `fm_merge_target_from_pr_url` correctly refused `https://gitlab.com/other/proj/pull/23` as a *repository* choice, so resolution fell through to the clone's sole remote — and a caller naming a pull request on another system got **PR 23 of the captain's own repository** merged instead. The repository was right; the pull request was one nobody named, and a merge does not come back. `ticket/pull/9` and `../../etc/pull/7` read the same way. Two parsers answering about one reference can disagree, so there is one.

**The url is parsed, not matched.** Three wrong-merge defects came out of this parser and all three were one shape — a value read from a reference that did not name it — so the third fix was not another pattern tweak. `fm_merge_target_parse_pr_url` takes the url apart in the order a url is defined: fragment off first, then query, then scheme, then host matched exactly against `github.com`, then a path of exactly four segments `<owner>/<repo>/pull/<digits>`. Both the repository and the number come out of that one parse, which is why they can no longer disagree.

The accepted shape is exactly `http(s)://github.com/<owner>/<repo>/pull/<digits>`, with an optional query and fragment that name no second pull request. Four things are refused rather than repaired, and each is gated as its own case so that no single tweak can silently re-open one:

| refused | why |
| --- | --- |
| a foreign host | `https://gitlab.com/other/proj/pull/23` would otherwise lend its number to whichever repository the remotes resolved |
| a second `/pull/<n>` in the query | a reference names exactly one pull request; one naming two is ambiguous about its own subject |
| a second `/pull/<n>` in the fragment | the same rule at the other delimiter, gated apart because they are parsed at different steps |
| anything trailing in the path | `/files`, `/commits/abc`, `/12/files/pull/77`. Trimming is how a url that says one thing came to mean another |

Refusing a url a human could have meant costs one trimmed paste. Accepting one costs a merge.

**And the number is read at the same `/pull/` the slug was.** Taking the *last* `/pull/<n>` instead of the first was a wrong-merge of its own: `https://github.com/<owner>/<repo>/pull/12?next=/pull/99` merged **PR 99**. The repository agreed with itself, so no cross-check could catch it — the only wrong thing was which pull request, and a merge does not come back. Both parsers now read the first occurrence, so the number and the repository always describe the same reference.

**And the reference must agree with the target.** Restricting the number to a validated github.com URL closes the foreign-host half; this closes the rest. A well-formed URL for `other/proj` combined with `--remote origin` passed both checks on their own terms — the URL was a valid GitHub PR reference, the target was explicitly named — and then only the *number* survived the URL, merging PR 23 of the captain's own repository. Two statements about one merge that disagree do not average into an answer: PR 23 in `other/proj` is a different pull request from PR 23 in `stoneevenson-biz/firstmate`, and nothing in the input says which was meant. So a URL naming a repository other than the resolved target refuses, naming both — exactly as an ambiguous remote set does. A bare number claims no repository and conflicts with nothing; a URL naming the target agrees with it and merges.

Three smaller properties fall out of the same discipline. A slug's segments may not be `.`, `..`, or lead with `-` — those pass a character-class check but are not GitHub names, and the contract says a malformed slug is refused rather than cleaned up. When a remote's URL is printed raw (a `BADREMOTE` detail, or an `AMBIGUOUS` row for a candidate that is not a GitHub repository), its userinfo is redacted — including the scp-style `user@host:path` form: the reader still sees which URL was no help, and a token embedded in a non-GitHub remote does not reach a banner. And an *empty* `--repo=` or `--remote=` refuses rather than reading as "no flag given", which would hand the decision back to the remote set the caller was in the middle of overriding; `--repo=` is a typo, not consent.

`--dry-run` shell-quotes each passthrough argument, because a printed command the caller cannot paste back is not the "exact command" it claims to be. The quoting is for *printing* only — the real invocation passes an argv, which needs none.

Because firstmate always has the PR URL — the crewmate reports it, `fm-pr-check.sh` records it — the ordinary call is `bin/fm-merge-pr.sh <id>` and it resolves through case 3 with nothing to type.

### What this does not change

Merge *authority* is untouched. `AGENTS.md` prime directive #2 still applies: no PR is merged without the captain's explicit word, or under an authorized `yolo` posture. This decides **where** a merge lands, never **whether** it may happen. It likewise does not require a Quarterdeck `approve:` verdict — `bin/fm-pr-check.sh` already gates arming the merge poll on one, and adding a second gate here was outside this change.

## The permission-profile rule

`~/.claude/settings.json` is machine-wide and the captain's; this repo does not edit it. The deny list currently holds:

```json
"Bash(gh pr merge*)",
"Bash(gh release*)",
```

The `gh-axi` half is missing, which is why the rail never fired on the mandated tool. The rules needed are:

```json
"Bash(gh-axi pr merge*)",
"Bash(gh-axi release*)",
```

These deny a *hand-typed* merge. They do not block `bin/fm-merge-pr.sh`, which invokes `gh-axi` from inside the script rather than as a Bash tool call — which is the intended effect: the pinned path stays open and the unpinned one closes.

## Every door, and a gate on each

The first three rounds of this guard were each rejected, and all three rejections were the same class of defect wearing a different coat.

1. Any string containing `/pull/<digits>` was accepted, so `https://gitlab.com/other/proj/pull/23` lent its `23` to whichever repository the remotes happened to resolve.
2. A url whose query or fragment held a second `/pull/<n>` merged *that* number, while every cross-check saw a repository agreeing with itself.
3. `-Rowner/repo` placed after `--` walked past a blocklist that knew only the detached spellings — and `gh` keeps the **last** repo flag it is given.

Each round asked *"is this reference valid?"*, patched the one input it had been shown, and shipped.
That is the wrong question, and asking it three times is why the answer was wrong three times.
A pull-request reference is one door.
It was never the only one.

The question this design asks instead is:

> Can any input, in any position, cause a merge against a repository other than the one resolved from this clone's `origin`?

Asked that way, the doors enumerate themselves.

| door | how it redirects a merge | how it is closed |
| --- | --- | --- |
| the PR reference | a url that names, or appears to name, another repository or another number | `fm_merge_target_parse_pr_ref` — one parse, both answers, and a **named reason** per rail |
| argument passthrough | `-R`/`--repo` after `--`, in any spelling; `gh` keeps the last one | an **allowlist** of sanctioned long options; every short flag refused wholesale |
| repeated flags | `--repo` twice, or `--repo` and `--remote` naming different repositories | repetition and disagreement both refuse; no precedence resolves them |
| the environment | `GH_REPO` names a default repository and `GH_HOST` a default server; `GIT_DIR` overrides `git -C <dir>` outright | the first two are **pinned** at the exec; the git environment is **scrubbed** on every remote read |
| the target itself | a repository that was named, but named by something the caller was handed | the **origin proof**: the target must equal this clone's `origin`, or be affirmed |
| the finished command | a construction that is correct today and is refactored tomorrow | the **egress check**: the argv is re-read and must pin the target exactly once |

### An allowlist, because a blocklist is a promise nobody can keep

A blocklist is a promise to have imagined every input.
Round three's guard listed `-R`, `--repo`, `--repo=` and `-R=`; `-Rowner/repo` was a fifth spelling, and `-dR owner/repo` a sixth, because a short flag may cluster *and* may carry its value attached.
"Does this short flag name a repository?" is a question a list of literal strings cannot answer.

So the merge command is no longer sanitised — it is **constructed**, from components that were each validated on their own:

- a number proved to be digits, by the same parse that produced the repository;
- a target proved to be a well-formed `owner/name`;
- passthrough options drawn from a fixed set in `bin/fm-merge-target-lib.sh`.

Short flags are refused as a class rather than case by case, which costs a caller four characters and closes the whole family.
An option `gh` grows that is not in the set refuses with a message saying to add it: a stale list costs one refusal and one commit, and a permissive one costs a merge.

The set also declares each option's *arity*, and that declaration is a belief about `gh` rather than something this code can check — so it is deliberately not load-bearing.
An option's value is skipped rather than read as a flag, but a value that could itself name a repository (`--body -Rowner/repo`) is **refused**, in both the detached and the inline form.
If the arity belief were ever wrong, the word we skipped as a value would be a flag to `gh`; refusing it means that possibility costs a reworded merge-commit body instead of a merge.

### The environment names a repository too

Two of these were found by asking the question of the environment rather than of the arguments, and one of them is worse than it looks.

`GH_REPO` and `GH_HOST` are read by a `gh`-shaped tool without appearing in its argv, and the same `owner/name` on a different host is a different repository.
Both are therefore **set** at the exec — `GH_REPO` to the resolved target, `GH_HOST` to `github.com`, which is not a policy choice but the only host `fm_merge_target_from_url` will resolve a repository from at all.

`GIT_DIR` is the sharper one, and it was verified rather than reasoned:

```
$ git -C A remote get-url origin
git@github.com:good/repo.git
$ GIT_DIR=B/.git git -C A remote get-url origin
git@github.com:attacker/loot.git
```

`git -C <dir>` is not the last word on which repository git reads.
An exported `GIT_DIR` would have redirected *both* the target resolution and the origin proof that checks it — to the same wrong clone, so the two would have agreed with each other perfectly and pinned a merge to a repository that appeared in no argument the reader could see.
Every git read in `bin/fm-merge-target-lib.sh` therefore goes through `fm_merge_target_git`, which scrubs `GIT_DIR` and its relatives, so the directory argument is the only thing that decides which repository is read.

Adjacent, and cheaper: every validation in that library is a bracket range, and a bracket range is a locale question.
`LC_ALL=C` is set (unexported, so it changes this file's pattern matching and nothing a caller runs) rather than left to whatever collation the machine happens to have.

### A boundary this does not close

`state/<id>.meta` supplies `project=` and `pr=`, and both are trusted.
A `project=` pointing at some other local clone whose `origin` is the attacker's would satisfy the origin proof honestly, because it would be that clone's origin.
This is a real limit, and it is bounded by a different rail: `state/` is written by firstmate's own spawn and `fm-pr-check`, and the permission profile does not give crewmates write access there.
It is recorded here so that the assumption is stated rather than assumed.

### The origin proof

Being *named* proves nothing was inferred.
It does not prove the name was meant.

A url, a remote name and a slug can all arrive from somewhere other than the person running the command — a pasted link, a `pr=` line recorded in a meta file, an exported variable — so any of them would otherwise be sufficient authority to leave `origin`.
The resolved target must therefore equal this clone's `origin`, and leaving it takes a second, separate word: `--allow-non-origin`.
That flag names no repository, so it can never itself be the thing that redirects a merge; it only affirms that the repository already named is meant to be somewhere else.

An `origin` that cannot be read at all refuses too, on its own rail (`target/origin-unprovable`).
"We could not check" and "we checked and it was fine" are the two answers a merge gate must never confuse.

Merging outside `origin` stays legitimate — an upstream contribution is exactly that — and stays loud.

### Named rails

Every refusal prints `REFUSED[<rail>]`, and each door has its own rail: `pr-ref/foreign-host`, `pr-ref/second-pull-in-query`, `pr-ref/second-pull-in-fragment`, `pr-ref/trailing-path`, `passthrough/repo-flag`, `target/duplicate-flag`, `target/ambiguous-remotes`, `target/not-origin`, `egress/*`, and the rest.

This is not decoration.
A refusal that proves only that *something* stopped is exactly what let three different holes look alike from the outside, and it is what a single "rejects bad input" gate would have gone on asserting through all three rounds.

### The permission profile is still the other half

The rail in `~/.claude/settings.json` still does not fire on the mandated tool.
The exact rules the captain needs to add are unchanged and stated in [The permission-profile rule](#the-permission-profile-rule) below.
This repo does not edit that file.

## Gates

| gate | freezes |
| --- | --- |
| `gate-t1-merge-target-resolution` | the rule: precedence, ambiguity as a stop naming every candidate, every URL form git stores, each refusal verdict on its own terms, and purity |
| `gate-t1-merge-repo-pinned` | the path: the merge command carries `--repo`, an ambiguous target refuses without invoking the tool, a single-remote clone still merges, and a non-origin target is announced |
| `gate-t2-merge-foreign-host` | a pull-request url on another host, or under a scheme that is not `http(s)`, refuses on its own rail |
| `gate-t2-merge-pull-in-query` | a second `/pull/<n>` in the query refuses; an innocent query still merges |
| `gate-t2-merge-pull-in-fragment` | a second `/pull/<n>` in the fragment refuses; an innocent fragment still merges |
| `gate-t2-merge-trailing-path` | path segments after the number refuse rather than being trimmed |
| `gate-t2-merge-passthrough-repo-flag` | every `-R`/`--repo` spelling after `--` refuses — detached, inline, attached, clustered, and one posing as a sanctioned option's value — and the allowlist admits only sanctioned long options |
| `gate-t2-merge-duplicate-repo-flag` | a target flag given twice, or a `--repo`/`--remote` disagreement, refuses; an agreement does not |
| `gate-t2-merge-ambiguous-remotes` | a bare number in a multi-remote clone refuses, naming every candidate, and announces no target |
| `gate-t2-merge-env-redirect` | `GH_REPO` and `GH_HOST` are pinned at the exec and `GIT_DIR` is scrubbed from every remote read, each proved against a control showing the redirect really works |
| `gate-t2-merge-origin-proof` | the target must be proved equal to `origin`, or affirmed with `--allow-non-origin`; an unreadable origin refuses |
| `gate-t2-merge-argv-egress` | the finished argv is re-read and must pin the resolved target exactly once |

The ten `gate-t2-*` gates are one per door, and that is the design rather than an accident of organisation.
A single "rejects bad input" gate would have gone green after round one and stayed green through rounds two and three, because each patch really did fix the input it was shown.
Ten narrow gates cannot do that: no regex, and no refactor of one, can reopen a door without the gate that names that door going red.
Four of them (the url rails) were already closed when they were written, and are gated anyway — an untested closure is an assumption, and the assumption these gates replace is the one that cost three rounds.

Both fixtures carry **both** an `origin` and an `upstream`, and the stub `gh-axi` is pointed at the *wrong* remote on purpose: absent `--repo` it records `merged-into=kunchenguid/firstmate`. `gate-t1-merge-repo-pinned` proves that inference first, as a control, so every "targets origin" assertion after it is a claim about the code rather than an artefact of a stub with nowhere else to go.

No test runs a real merge against a real remote. The boundary is stubbed; the fixture remotes are URLs that are never fetched.
