# Every Enter fm-spawn sends is accounted for

Status: implemented, 2026-09-02.
Incident: spawned panes found at an empty composer with the brief never submitted, and crewmates found dead with the trust dialog resting on `No, exit`, repeatedly across 2026-08-28..09-02.
Gates: `gate-t4-launch-enter-waits-for-echo`, `gate-t4-readiness-proves-the-queue-drained`, `gate-t4-launch-enter-never-reaches-the-agent`, `gate-t4-stale-dialog-is-not-live`, `gate-t4-ready-shell-adds-no-extra-probes`.
Implementation: `bin/fm-herdr.sh`, consumed by `bin/fm-spawn.sh`.

## The defect

`bin/fm-spawn.sh` launched a crewmate with `fm_herdr_run "$T" "$LAUNCH"`, and `herdr pane run` sends the text and the Enter in one unacknowledged call.
The binary says so itself, in `herdr pane send-text --help`: "herdr pane run `<PANE_ID>` `<COMMAND>` sends text and Enter in one call".
So the Enter went in whether or not the surface was ready to consume it, and nothing afterwards could tell a submitted launch from a buffered keystroke.

That would be an annoyance on its own.
It is a safety bug because of what the keystroke can reach.
The first dialog a fresh claude pane renders is the trust prompt, and its default option is `No, exit`.
An Enter that arrives there does not merely fail to launch: it answers a safety dialog with its destructive default and kills the agent.
Both observed endings are the same defect - a brief left unsubmitted in a composer is the keystroke landing early, and a dead agent with the dialog resting on `No, exit` is the keystroke landing late.

The second half is what made surplus keystrokes exist in the first place.
`fm_herdr_wait_shell_ready` computed one marker before its retry loop and re-sent the same probe line on every outer iteration, opening on the first sighting of that marker.
Because every probe carried the same marker, the echo that satisfied the gate was not attributable to any particular probe: probe 1's output opened the gate while probes 2..N were still unconsumed keystrokes.
Each of those is a full command line terminated by Enter that fm-spawn had typed and could no longer account for.
herdr routes keys to an agent as soon as it has classified one in the pane, so an Enter fm-spawn cannot account for is an Enter it cannot say who will consume.

The readiness gate proved that *a* shell ran *a* probe.
It never proved the pane's input queue was empty, and only the second property keeps a keystroke away from a dialog.

## The rule

**Never send Enter into a surface that has not proven it is ready to consume it, and account for every Enter that has already been sent.**

Four obligations, each with one implementation in `bin/fm-herdr.sh`.

### 1. One probe, one marker

`fm_herdr_wait_shell_ready` gives each probe its own ordinal marker and opens only on the echo of the *latest* probe sent.
A pane's input is FIFO, so that echo is simultaneously proof that every earlier probe was consumed.
The happy path is unchanged in cost: probe 1 echoes and the gate opens on the first poll.

### 2. Drainedness is proven separately from readiness

`fm_herdr_input_drained` sends one unique sentinel, once, and requires it to round-trip.
It is never resent, because a resend would put back exactly the surplus it exists to rule out.
It runs immediately before the launch, so its echo is positive proof that the queue is empty at the instant the launch line is typed.

### 3. The launch is text, then proof, then Enter

`fm_herdr_launch_line` replaces the one-call blind path with the manual recovery that has worked every time, in code.
`herdr pane send-text` puts the line in without an Enter; `herdr pane wait-output` waits for the tail of that line to appear, which is the acknowledgment the old path never had; only then is the Enter pressed.
The witness is the command's tail rather than its head, because a terminal echoes what it received in order, so seeing the last characters proves the whole line arrived where a prefix would pass on a line cut in half.
No echo means no Enter at all - a launch that was never typed is a pane to inspect, not a keystroke to gamble on.

The Enter goes to `herdr pane send-keys`, never `herdr agent send-keys`.
`fm_herdr_send_key` deliberately prefers the agent verb because its job is clearing a dialog an agent is holding; that preference is exactly wrong here, and reusing it would make the launch Enter itself capable of answering the dialog it exists to avoid.
`fm_herdr_pane_key` is the pane-only sibling, and one last check for a live dialog stands between the text and the Enter.

### 4. A dialog is live only if the agent says so

`fm_herdr_dialog_live` reads `agent_status` as a field.
Pane text cannot answer the question: `recent` is scrollback-backed, so a trust dialog answered ten minutes ago renders exactly like one waiting for an answer now, and `visible` is a viewport a scrolled-back pane can still be showing.
The field is read as a field rather than grepped out of the record, because an agent record carries the crewmate's own terminal title beside it, which is untrusted rendered text.

## The two costs, taken deliberately

A refused launch leaves the line typed but unsubmitted in the pane.
That residue is the point rather than a rough edge: an abandoned half-typed line is a pane to inspect, where a fired Enter is a dialog answered, and `bin/fm-spawn.sh` says so in the error it exits with.
Nothing tries to tidy it up, because every candidate for tidying is another keystroke aimed at a pane whose state is exactly what is in doubt.

The gate fails closed, and there is no override for it.
If a pane never renders what was typed into it, no crewmate launches there at all.
That is a real operational risk and it is accepted knowingly: readiness has already proven the pane is a shell at a prompt that renders what it is sent, so a launch line that does not appear is a pane worth stopping on.
`FM_SKIP_SHELL_READY=1` still skips readiness and drainedness for tests, and deliberately does not skip the Enter gate - the one obligation that is never optional.

## What is out of scope

What the trust dialog asks, and how a human answers it, are unchanged.
`stuck-crewmate-recovery`'s manual clearing step still goes through `fm_herdr_send_key`, which still prefers the agent verb, because clearing a dialog is precisely the case where the agent is the right target.
The pre-cutover tmux drain path is untouched; `fm-spawn` has not launched onto it since the herdr cutover.

One blind Enter deliberately remains, and the title of this spec should not be read as covering it.
`bin/fm-spawn.sh` still runs `fm_herdr_run "$T" 'treehouse get'` into a freshly created pane, before any readiness proof exists to have.
It is the same one-call primitive and the same race class, and it is left alone because its consequence is different in kind: no agent occupies that pane yet, so there is no dialog for a stray keystroke to answer, and a `treehouse get` that does not take is caught by the cwd wait immediately after it.
Closing it would mean proving readiness on a pane that has existed for a few milliseconds, which is a separate change with its own cost.

`fm_herdr_pane_key` narrows the launch Enter to the pane verb, and that is worth doing, but it is not what makes the launch safe.
herdr routes input by what occupies the pane rather than by which verb was typed, so once an agent is classified there the pane verb reaches it too.
The guarantee rests on `fm_herdr_dialog_live`, and that is a field read, which can lag the pane it describes.
The residual window - an agent classified but not yet reporting `blocked` - is unreachable from `fm-spawn`, which creates a fresh tab per task and refuses a duplicate label, so no agent occupies the pane at launch time.
Any future caller that launches into a reused pane inherits that window and would need more than this.

## Gates

| gate | proves |
|---|---|
| `gate-t4-launch-enter-waits-for-echo` | against a pane that never echoes, the launch submits NOTHING - no Enter is logged and no agent starts - while the one-call path it replaced puts an Enter straight into the same pane |
| `gate-t4-readiness-proves-the-queue-drained` | with the race constructed deliberately - a shell that stays busy long enough for a second probe to go out, then consumes one line per observation - readiness opens only with the pane's input queue empty, and the drain sentinel is sent exactly once |
| `gate-t4-launch-enter-never-reaches-the-agent` | a pane holding a live dialog refuses the launch Enter and nothing reaches the agent's input; on the happy path the Enter is still routed to the pane and `agent send-keys` is never called |
| `gate-t4-stale-dialog-is-not-live` | a trust dialog rendered in scrollback with the agent idle is not live, while a blocked agent is - and a record whose terminal title spells out every status word does not fool it |
| `gate-t4-ready-shell-adds-no-extra-probes` | against an immediately-ready shell the whole gated launch costs exactly two probes, one text send and one Enter, and leaves nothing for the agent to inherit |

All five live in `tests/fm-spawn-t4-enter-race.test.sh`, one case each.
One combined "the launch is safe" gate would have gone green the moment any single property was fixed, which is the false green this ledger exists to prevent.

The fake herdr in that suite models a real pty rather than a yes-machine: keystrokes are queued, a shell consumes them at its own pace, and whatever is still queued when the agent starts is inherited by the agent.
Without that model the race could only be hoped against, not constructed.
The first gate proves the model is load-bearing before it asserts anything, by showing that the blind path does put an Enter into the very same non-echoing pane.

Red-first evidence, against the code as it stood: `readiness opened with 1 keystroke(s) still unconsumed in the pane`, `a genuinely blocked agent was not reported as holding a live dialog`, `the drain sentinel refused an immediately-ready shell`, `launch failed against a ready, echoing pane`, and `no gated launch primitive: the launch still sends text and Enter in one blind call`.
