# An empty composer padded with a non-breaking space is still empty

Status: implemented
Gates: `gate-t4-landed-steer-not-reported-swallowed`, `gate-t4-swallowed-enter-still-refused`
Incident: send-false-negative (observed 2026-08-28)

## What happened

firstmate sent a merge authorization to `fm-fmx-plat`. `bin/fm-send.sh` reported

```
error: text not submitted to <target> (Enter swallowed; text left in composer)
```

while the pane showed the prompt accepted and the agent already thinking. The
steer had landed.

A false failure here is worse than it sounds. For an *authorization* or a
*steer*, the natural response to "it did not land" is to send it again, and the
agent then acts twice. And the whole point of the verified-submit model is that a
supervisor learns when an instruction did not land; a detector that cries wolf
destroys exactly that trust, so the next real failure is read as noise.

## The cause: a locale, not a race

`fm_tmux_composer_state` in `bin/fm-tmux-lib.sh` classifies the pane's cursor row.
It captures the row with `tmux capture-pane -e`, drops dim/faint ghost text,
strips the harness's box-drawing borders, trims surrounding whitespace, and asks
whether anything real is left. A bare prompt glyph counts as empty, and an empty
composer is the positive acknowledgement that a submit landed.

A live Claude Code pane pads its **empty** composer with `U+00A0 NO-BREAK SPACE`,
not an ASCII space. Captured verbatim from `tmux capture-pane -e` against
`claude` v2.1.258 on 2026-09-02:

```
empty composer   342 235 257 302 240          ->  U+276F  U+00A0
typed composer   342 235 257 302 240 m e ...  ->  U+276F  U+00A0 "merge it"
```

The trim uses `[[:space:]]`, whose meaning **depends on the locale bash was
started in**. Measured on the same fixture:

| locale | bash 3.2.57 | bash 5.3.15 |
| --- | --- | --- |
| `LC_ALL=C` | padding kept | padding kept |
| `LC_ALL=POSIX` | padding kept | padding kept |
| `LC_ALL=en_US.UTF-8` | trimmed | trimmed |
| none set | padding kept | trimmed |

Where the padding is kept, the stripped row stays `❯<NBSP>`, fails the
bare-prompt-glyph case, matches no busy footer, and falls through to `pending` —
"text left in composer". Same pane, same bytes, opposite verdict, decided by an
environment variable that nothing in the pane reflects. That is why it looked
intermittent and why nothing on screen explained it.

The same read backs `fm_pane_input_pending`, so in a C-locale session every
**idle** claude pane also reads as holding pending input. That is incident
`afk-invx-i5` returning through a different glyph: there the detector recognised
only a bare `> ` and claude's box borders defeated it; here the borders are
handled and the *padding* defeats it.

Why the existing suite stayed green: every composer fixture in it was written
with ASCII spaces, because that is what a person writing a fixture types, and the
suite ran in whatever locale the machine happened to have. A fixture written in
ASCII cannot exhibit this, and a suite that does not pin the locale passes or
fails by accident.

This library's own header states that it is byte-wise and locale-independent —
"`LC_ALL=C` makes awk walk bytes", "bash 3.2 safe, locale-independent — no `\u`
escapes, no multibyte character classes". The trim quietly was not.

## The fix

`fm_tmux_fold_blanks` replaces the non-ASCII blanks a harness may pad with
(`U+00A0`, `U+2002`, `U+2003`, `U+2007`, `U+2009`, `U+200B`, `U+202F`, `U+3000`,
`U+FEFF`) with an ASCII space. `fm_tmux_composer_state` calls it between the ghost
strip and the border strip — ahead of the trim, which is the step whose meaning
moved. The classification is then the same in every locale, which is what the
file already claimed.

The list is written as `printf` octal escapes so the source stays plain ASCII: an
invisible NBSP sitting in a source file is unreviewable.

The rule has one implementation, and both callers of the detector — `fm-send.sh`
and the away-mode daemon's injection check — get it from there. The daemon itself
is unchanged.

### Why this is a narrowing, not a loosening

The constraint that shaped this fix: do not make the false negative go away by
loosening the detector into always-success. A false negative is annoying; a false
*positive* — reporting a lost steer as delivered — is the failure this mechanism
exists to prevent, and it is strictly worse.

Folding invisible padding onto a space can only turn a blank into the blank it
already is. Real text on the row still classifies as `pending`. The single way
the fold could ever report a lost steer as delivered is a steer composed
*entirely* of invisible blank characters, which is not a steer; that boundary is
pinned by a test rather than left as an assumption.

Alternatives considered and rejected:

- **Treat a busy pane as proof of submission.** Unsafe: a harness that was
  already mid-turn when the text was typed is busy for a reason that has nothing
  to do with this steer.
- **Require the residual text to match what was typed.** Unsafe in the other
  direction: a harness that renders anything after the typed text inside the box
  (a counter, a hint) would stop matching, and a genuinely swallowed Enter would
  be reported as delivered.
- **Demand a coherent (stable) read, treating instability as unknown.** Sound in
  principle, but measurement found no race to fix: 546 consecutive reads of a
  live pane through a streaming turn produced zero non-empty classifications and
  zero cursor-position changes across the capture. It would have been a fix for a
  cause that was not there.

## Evidence

Against a live `claude` v2.1.258 pane in an isolated tmux server, with the
detector run under `LC_ALL=C`:

| state | before | after |
| --- | --- | --- |
| empty composer (`❯` `U+00A0`) | `pending` | `empty` |
| composer holding `merge it` | `pending` | `pending` |
| `fm_tmux_submit_core`, steer that landed | `pending` → "Enter swallowed" | `empty` |

In the third row the pane simultaneously showed `❯ merge PR 42, checks are green`
accepted and the agent working on it — the incident, reproduced.

Mutation check on the gate pair: replacing the detector's body with
`printf empty` (the lazy "always report success" fix) makes
`gate-t4-landed-steer-not-reported-swallowed` pass and
`gate-t4-swallowed-enter-still-refused` fail. The second gate is therefore doing
the work it exists for.

## Gates

Two, because one direction alone would be meaningless.

- `gate-t4-landed-steer-not-reported-swallowed` — `tests/fm-send-t4-landed.test.sh`.
  The direction that was broken: a landed steer is reported as delivered.
- `gate-t4-swallowed-enter-still-refused` — `tests/fm-send-t4-swallowed.test.sh`.
  **The one that matters.** A genuinely swallowed Enter still exits non-zero and
  says so. Without it, "always report success" would pass.

Both suites share `tests/send-composer-helpers.sh`, whose fixtures are the real
captured bytes and which asserts every classification across
`fm_composer_locales()` — `C` and `POSIX`, which are guaranteed to exist and are
the two that break the trim, plus a UTF-8 locale when the machine has one. The
property under test is that the answer is the *same* in all of them, so neither
gate can pass or fail by inheriting the runner's environment.
