# A PR reference is validated, never compiled

Status: implemented, 2026-09-02.
Gate: `gate-t5-prcheck-ref-not-compiled`.
Implementation: `bin/fm-pr-check.sh` and `bin/fm-poll-lib.sh`, calling `fm_merge_target_parse_pr_ref` in `bin/fm-merge-target-lib.sh`.

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

### 2. The seatbelt: emit from the components, serialised with `%q`, from a library

Validation alone is not the whole answer, and the reason is concrete: the parser deliberately accepts an optional query and fragment that name no second pull request.
So `https://github.com/o/r/pull/1?x=";touch ./EVIL;"` **parses**, and under the old writer it would still have injected.

The poll script is therefore rendered from the two values the parse yields, each serialised by `printf %q`.

That rendering lives in `bin/fm-poll-lib.sh` rather than inline in the writer, and the reason is that **inline, it was untestable**.
The caller upstream is `fm_merge_target_parse_pr_ref`, which only ever yields a digits-only number and a `[A-Za-z0-9._/-]` slug - so `%q` was never handed anything that needed quoting, both calls could be deleted, and every assertion still passed.
A defence whose removal no gate can detect is not a defence.
At its own seam a test can hand the rule a separator, a quote, a space, a command substitution and a newline directly, and prove each arrives at `gh` as one unchanged argument:

```
$ bash bin/fm-poll-lib.sh 7 '; touch ./OWNED; :'
state=$(gh pr view 7 --repo \;\ touch\ ./OWNED\;\ : --json state -q .state 2>/dev/null)
[ "$state" = "MERGED" ] && echo "merged"
```

**`%q` is what makes this half independent, and wrapping the components in literal quotes would not have been.**
The first cut of this fix emitted `'$PR_SLUG'`, and its safety rested on the parser never emitting a `'` - which is not independence, only a different dependency from the `"` the original defect turned on.
`printf %q` is bash's own "quote this so it re-reads as exactly this one word", decided by the content rather than by a quote this file hopes never arrives:

```
component: '; touch ./OWNED; :'

literal single quotes ->  gh pr view '7' --repo ''; touch ./OWNED; :'' ...   # creates ./OWNED
printf %q             ->  gh pr view 7 --repo \'\;\ touch\ ./OWNED\;\ :\' ...   # creates nothing
```

**What the seatbelt does not cover, and the gate still owns.**
`%q` settles the shell layer only.
It cannot make a component *mean* the right thing to `gh`: a loosened parser emitting `-Rowner/other` would yield one safely-quoted word that `gh` still reads as an attached repo flag - the family `fm_merge_target_names_repo` exists for in `docs/specs/2026-08-31-merge-target-pin.md`.
So the honest claim is narrow: independent at the shell layer, never a substitute for the parse.

A side benefit, and an alignment with that same spec: pinning `--repo` means the poll names the repository it asks about rather than leaving `gh` to infer one from whatever clone the watcher happens to be standing in.

### 3. The line rule: a control character is not a reference

`pr=<url>` goes into `state/<id>.meta`, a **line-oriented** file whose every reader parses with `grep '^key=' | tail -1`.
A newline in the reference is therefore a forged record, and because readers take the last one, the forged record **wins**.

The parser cannot answer this, and that is not a flaw in it: it strips the query and fragment *before* validating anything, so a control character living in either parses perfectly well.
Verified against the shared parser:

```
$ fm_merge_target_parse_pr_ref $'https://github.com/example/repo/pull/7?x=\nworktree=/tmp/attacker\nharness=sh'
OK	example/repo	7
```

Under the first cut of this fix, that reference armed successfully and the meta then answered:

```
worktree -> /tmp/attacker-controlled
harness  -> sh
```

`bin/fm-teardown.sh` reads `worktree=` that way, so a forged record redirects what a teardown acts on.

Encoding for a line-oriented file is `bin/fm-pr-check.sh`'s own concern rather than the shared parser's, so the rail lives here: any control character in the reference refuses as `REFUSED[pr-ref/control-character]`, ahead of the parse and ahead of every side effect.
`bin/fm-merge-target-lib.sh` stays unedited.

**And refusing the character is only half the job.**
The first version of this rail was paired with `echo "pr=$URL" >> "$META"`, which reopened the same hole by a different door: with `xpg_echo` set - a shell option `BASHOPTS` carries in from the environment into any non-interactive bash - the `echo` builtin expands backslash escapes, so a reference whose query holds the two characters `\` and `n` has **no control character to refuse**, passes the rail, passes the parse, and becomes real newlines at the moment of the write.

```
reference:  https://github.com/example/repo/pull/7?x=\nworktree=/tmp/pwn\nharness=sh

with echo under xpg_echo ->  worktree -> /tmp/pwn      harness -> sh
with printf '%s\n'       ->  worktree -> <unchanged>   harness -> echo
```

The inconsistency was the bug: the poll script was already written with a literal format and the value as data, and the meta line was not.
It is now `printf '%s\n' "pr=$URL"`, which holds whatever the shell's options happen to be rather than relying on this file having imagined them.

### What is still recorded raw

`pr=<url>` in `state/<id>.meta` keeps the reference as given - but only a reference that has both cleared the control-character rail and parsed, so it can no longer be more than one line.
`bin/fm-merge-pr.sh` and `bin/fm-teardown.sh` read that line back through the same parser.
It is data those readers validate, never shell anybody executes.

## What is out of scope

- `bin/fm-merge-target-lib.sh` is unchanged. This slice calls it; it does not edit it.
- The other findings from the audit that produced this task - the merge-path verdict gate, the verify prefix match, the project-mode bracket - are separately owned.
- **`bin/fm-pr-check.sh` is the only writer of `state/*.check.sh` in the repo.** `AGENTS.md` section 7 documents a hand-written custom `state/<id>.check.sh` contract for firstmate itself, but no script compiles one; the other references to the path are readers (`bin/fm-watch.sh`) and deleters (`bin/fm-teardown.sh`). A future second writer inherits this rule rather than re-deriving it.

## Gates

`gate-t5-prcheck-ref-not-compiled` - `tests/fm-prcheck-url-injection.test.sh`.

It proves three vectors and the honest path:

- **A, the validator's**: an unparseable reference refuses with a named rail, writing no `check.sh` and appending no `pr=`;
- **B, the seatbelt's**: an **accepted** reference carrying shell metacharacters in its query arms a poll whose generated script is byte-identical to the components-only rendering, and which creates no file when run;
- **C, the line rule's**: a reference carrying a newline refuses as `control-character`, and the meta keeps exactly one `worktree=` and its original `harness=`;
- **D, the line rule's other half**: a reference carrying a literal `\` `n` - no control character, so correctly *not* refused - still leaves exactly one `worktree=` and the original `harness=` when the script is run under `env BASHOPTS=xpg_echo`. The vector proves the option is actually on before relying on it, since a bash that ignored `BASHOPTS` would make it vacuous. (`env`, not a `BASHOPTS=... cmd` prefix: `BASHOPTS` is readonly inside a running bash, so the prefix form fails the assignment and runs with the option off.)
- **E, the seatbelt at its own seam**: `fm_poll_render` is handed a separator, a quote, a double quote, a command substitution, a space and a newline, and for each the rendered poll is valid shell, executes nothing, and delivers the component to `gh` as exactly one argument compared byte for byte with `cmp`;
- the honest path: a valid url still arms a poll that prints `merged` for a `MERGED` PR, prints nothing for an `OPEN` one, and pins `--repo` in the `gh` argv. That last assertion polls a pull-request number no other vector uses and truncates the recorded argv first, so another vector's identical invocation cannot satisfy it.

Every byte-for-byte claim is made with `cmp` against a file, never with `[ "$(cat ...)" = ... ]`: command substitution strips trailing newlines, so a string comparison accepts a file missing its terminal newline or carrying extra blank lines and still calls the result byte-identical.

Under `LEDGER_MUTATE=1` each vector asserts the injection **succeeds**, and each proves it by *observing the injected effect* rather than by observing that something was armed: A runs the generated poll and demands `./PWNED`, B runs it and demands `./EVIL`, C demands the forged `worktree=` record win.
Run against the actual pre-fix revision those mutation branches pass, which is what makes them a proof rather than a formality; against a correct implementation they fail, which is what `ledger freeze` requires.
Vectors D and E were each proved non-vacuous the same way, by removing the single defence each one covers and watching the gate go red: restoring `echo` for the meta write fails D (`xpg_echo expanded the escape into a forged worktree= record`), and deleting both `%q` calls fails E (`a hostile component executed: ; touch ./OWNED; :`).
