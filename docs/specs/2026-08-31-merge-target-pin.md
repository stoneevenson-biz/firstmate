# The merge target is named, never inferred

Status: implemented.
Gates: `gate-t1-merge-target-resolution`, `gate-t1-merge-repo-pinned`.

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

## Gates

| gate | freezes |
| --- | --- |
| `gate-t1-merge-target-resolution` | the rule: precedence, ambiguity as a stop naming every candidate, every URL form git stores, each refusal verdict on its own terms, and purity |
| `gate-t1-merge-repo-pinned` | the path: the merge command carries `--repo`, an ambiguous target refuses without invoking the tool, a single-remote clone still merges, and a non-origin target is announced |

Both fixtures carry **both** an `origin` and an `upstream`, and the stub `gh-axi` is pointed at the *wrong* remote on purpose: absent `--repo` it records `merged-into=kunchenguid/firstmate`. `gate-t1-merge-repo-pinned` proves that inference first, as a control, so every "targets origin" assertion after it is a claim about the code rather than an artefact of a stub with nowhere else to go.

No test runs a real merge against a real remote. The boundary is stubbed; the fixture remotes are URLs that are never fetched.
