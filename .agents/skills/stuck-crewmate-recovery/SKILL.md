---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.

## Reading a steer's outcome

Delivery to a herdr pane is acknowledged rather than inferred, so `bin/fm-send.sh` names which failure you hit instead of leaving you to guess.

- **Refused at an approval dialog** - the crewmate is blocked and was not typed over.
  Clear the dialog first with `bin/fm-send.sh <window> --key <choice>`, then send the corrective line.
- **Refused because the pane holds no agent** - nothing was delivered, and deliberately nothing was executed, since a pane holding a shell would have run the steer as a command.
  Peek it: the agent has exited or is still starting, which is step 4 territory, not another steer.
- **Delivered but unconfirmed** - a warning, not an error.
  Treat it as delivered and do not re-send it; re-sending a steer the crewmate already holds is the worse of the two errors.
- For a pane that predates the herdr cutover the old rule still holds: only a positively confirmed swallow, with the text left in the composer, is a failure.
