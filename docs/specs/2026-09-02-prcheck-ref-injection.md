# A PR reference is validated, never compiled

Status: implemented, 2026-09-02.
Gate: `gate-t5-prcheck-ref-not-compiled`.
Implementation: `bin/fm-pr-check.sh`, calling `fm_merge_target_parse_pr_ref` in `bin/fm-merge-target-lib.sh`.

## The defect

`bin/fm-pr-check.sh` wrote the watcher's per-task merge poll with an **unquoted** heredoc:

```sh
cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
```

`$URL` was expanded at write time and landed inside a double-quoted word of the generated file.
A `"` in the url closed that word, and everything after it became shell.

`bin/fm-watch.sh` then ran that file as `timeout "$CHECK_TIMEOUT" bash "$c"` every `FM_CHECK_INTERVAL` seconds - 300 by default - for as long as the task stayed armed.

There was no validation of `$URL` at all: not a schema check, not a substring check.

**The input is crewmate-controlled by design.**
`AGENTS.md` section 7 has the crewmate report `done: PR <url>` and has firstmate paste that value straight into `bin/fm-pr-check.sh <id> <url>`.

Reproduced end to end before the fix, with the argument `https://github.com/o/r/pull/1"; touch ./PWNED; :"`:

```
state=$(gh pr view "https://github.com/o/r/pull/1"; touch ./PWNED; :"" --json state -q .state 2>/dev/null)
[ "$state" = "MERGED" ] && echo "merged"
```

`bash -n` accepts it as valid shell, and running it created the file.

Two things make this worse than an ordinary injection.

1. **The permission profile does not reach it.**
   The deny rules in `~/.claude/settings.json` apply to top-level Bash tool calls.
   The payload runs inside a script the watcher invokes, so nothing in the profile is consulted.
2. **It sits upstream of a gate that is otherwise correct.**
   The poll's own comparison `[ "$state" = "MERGED" ]` is exact and fail-closed.
   The whole hole was in how the argument became code.

The blast radius is the firstmate session itself: the one that holds the helm and merge authority, on a timer, indefinitely.

## The rule

**A PR reference is parsed before anything happens, and the poll script is written from the parse rather than from the argument.**

Two independent halves, because neither one covers the other's vector.

### 1. The gate: it parses, or nothing happens

`fm_merge_target_parse_pr_ref` is already this repo's single-walk PR-reference parser - the rule `bin/fm-merge-pr.sh` proves a merge target with, built out of four wrong-merge defects.
It was never called here.
It is now, immediately after `URL=$2`, ahead of the Quarterdeck verdict gate and ahead of every side effect: a reference that does not parse writes no `state/<id>.check.sh`, appends no `pr=` line, and does nothing else.

This is a call, not a new validator.
Designing a second PR-reference rule beside the existing one is how the two would come to disagree, and a disagreement between them is a merge target and a poll target that name different repositories.

The refusal names the rail that produced it - `REFUSED[pr-ref/trailing-path]` and the rest of the parser's reason vocabulary - because a refusal that says only "invalid" costs another cycle to diagnose.

### 2. The seatbelt: emit from the components

Validation alone is not the whole answer, and the reason is concrete: the parser deliberately accepts an optional query and fragment that name no second pull request.
So `https://github.com/o/r/pull/1?x=";touch ./EVIL;"` **parses**, and under the old writer it would still have injected.

The poll script is therefore rendered from the two values the parse yields:

```sh
printf 'state=$(gh pr view %s --repo %s --json state -q .state 2>/dev/null)\n[ "$state" = "MERGED" ] && echo "merged"\n' \
  "'$PR_NUM'" "'$PR_SLUG'" > "$STATE/$ID.check.sh"
```

`PR_NUM` is digits; `PR_SLUG` passed `fm_merge_target_valid_slug`, whose character class is `[A-Za-z0-9._/-]`.
Neither can contain a quote, so the single quotes here cannot be closed from outside the way the old double-quoted url could.
The format string is a literal, so no expansion happens at write time beyond those two `%s`.

No caller byte reaches the generated shell, which is what keeps this safe even if the parser is later loosened.
The validator is the gate; the quoting is the seatbelt.

A side benefit, and an alignment with `docs/specs/2026-08-31-merge-target-pin.md`: pinning `--repo` means the poll names the repository it asks about rather than leaving `gh` to infer one from whatever clone the watcher happens to be standing in.

### What is still recorded raw

`pr=<url>` in `state/<id>.meta` keeps the reference as given, because it has parsed by then and because `bin/fm-merge-pr.sh` and `bin/fm-teardown.sh` already read that line through the same parser.
It is data those readers validate, never shell anybody executes.

## What is out of scope

- `bin/fm-merge-target-lib.sh` is unchanged. This slice calls it; it does not edit it.
- The other findings from the audit that produced this task - the merge-path verdict gate, the verify prefix match, the project-mode bracket - are separately owned.
- **`bin/fm-pr-check.sh` is the only writer of `state/*.check.sh` in the repo.** `AGENTS.md` section 7 documents a hand-written custom `state/<id>.check.sh` contract for firstmate itself, but no script compiles one; the other references to the path are readers (`bin/fm-watch.sh`) and deleters (`bin/fm-teardown.sh`). A future second writer inherits this rule rather than re-deriving it.

## Gates

`gate-t5-prcheck-ref-not-compiled` - `tests/fm-prcheck-url-injection.test.sh`.

It proves both vectors and the honest path:

- an unparseable reference refuses with a named rail, writing no `check.sh` and appending no `pr=`;
- an **accepted** reference carrying shell metacharacters in its query arms a poll whose generated script is byte-identical to the components-only rendering, and which creates no file when run;
- a valid url still arms a poll that prints `merged` for a `MERGED` PR, prints nothing for an `OPEN` one, and pins `--repo` in the `gh` argv.

Under `LEDGER_MUTATE=1` both vectors assert the injection **succeeds**, so a correct implementation fails the test.
