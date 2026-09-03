# Gate Ledger

## Drain list (2)

- [ ] gate-l2-loop-audit-level — loop-audit scores the repo at level L2 or better (score >= 58) (red) **ready**
- [ ] m1-hook-registered — bin/fm-boot-context.sh is registered as a real SessionStart hook (red) **ready**

## All gates

| id | status | title |
| --- | --- | --- |
| gate-g1-threshold | green | Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not |
| gate-g2-busy-guard | green | Busy-guard: an over-threshold pane that is busy does NOT fire |
| gate-g3-rehydrate | green | Rehydrate: SessionStart with handoff injects+archives it; no-handoff path unchanged |
| gate-g4-e2e | green | E2E on scratch pane: threshold -> checkpoint -> handoff -> /clear -> rehydrate |
| gate-g5-inject-cap | green | Inject cap: handoff under 10k injected verbatim, over 10k yields a pointer |
| gate-q1-verdict-grammar | green | Verdict grammar: only approve/reject/escalate/lens lines; last-decision and reject-count read correctly |
| gate-q2-merge-refuses-unverified | green | fm-merge-local refuses without a trailing approve verdict; approve merges; override is loud |
| gate-q3-prcheck-refuses-unverified | green | fm-pr-check refuses to arm the merge poll without a trailing approve verdict |
| gate-q4-reject-roundtrip | green | fm-verify: approve path records approve; reject relays findings to the crewmate and exits 2; non-ship tasks skip |
| gate-q5-attempt-cap | green | Third reject escalates instead of spinning; at-cap tasks escalate without re-running the verifier |
| gate-q6-lens-degrade | green | No Fugu key + no codex -> lens degrades to none loudly; verify still completes |
| gate-q7-fail-closed | green | Verifier infrastructure failure escalates - never approves |
| gate-i1-intake-grammar | green | Intake grammar: only proceed/revise/escalate/panel lines; last-decision ignores panel lines and no-decision files |
| gate-i2-spawn-refuses-unvetted | green | fm-spawn refuses a ship task without a trailing intake proceed; scout exempt; override loud |
| gate-i3-panel-roundtrip | green | fm-intake: both thinkers proceed -> proceed + synthesis; one revise -> revise with count; exit codes 0/2 |
| gate-i4-revise-cap-fail-closed | green | Second revise escalates; at-cap intakes escalate without running the panel; a PANEL-less thinker escalates, never proceeds |
| gate-i5-intake-lens-degrade | green | Intake with no Fugu key + no codex degrades the lens to none loudly; intake still completes |
| gate-l1-drain-instrumented | green | Wake drain appends a run-log JSON line and stamps STATE.md; FM_LOOP_LOG=0 disables; log failure never breaks the drain |
| gate-l2-loop-audit-level | red | loop-audit scores the repo at level L2 or better (score >= 58) |
| g-boot-digest | frozen | Boot-time reconciliation digest in captain context; fm-watch-arm --status read-only |
| m0-ledger-shape | frozen | Gate harness loads: gates/ledger.json is an array, and a broken ledger fails loudly |
| m1-hook-registered | red | bin/fm-boot-context.sh is registered as a real SessionStart hook |
| m2-boot-emitter-is-read-only | frozen | A full boot through bin/fm-boot-context.sh performs zero writes |
| m4-boot-budget-hostile | frozen | Boot holds its budget by enforced deadline and concurrent helpers, leaks nothing, and never elides a peer |
| m5-digest-never-silent | frozen | A section that fails to build says so; failure is never silent |
| gate-ci-declared-red | frozen | CI skips a test only when its gate is red AND declared accepted |
| gate-status-verb | frozen | Status reporting is a verb a crewmate whose redirect is refused can still use |
| gate-h2-mux-workspace-scoping | green | Workspace scoping: resolved by project label, FM_HERDR_WORKSPACE overrides, missing is created, never focus-luck |
| gate-h3-spawn-named-herdr-tab | green | fm-spawn lands a crewmate as a named herdr tab in the project workspace; an unreachable herdr stops it |
| gate-h4-send-peek-routed-by-meta | green | fm-send/fm-peek use acknowledged herdr delivery and route by the meta, never by ambience |
| gate-h5-herdr-live-roundtrip | green | LIVE herdr: workspace, tab, shell readiness, run/read, naming accepted by the binary, acknowledged send, close |
| gate-h1-herdr-only-surface | green | Selection: herdr is the only surface - no driver selector, no FM_MUX; an unreachable herdr escalates |
| gate-h6-drain-open-nothing-new-on-tmux | green | Cutover: nothing new is created on tmux, and the drain stays open for pre-cutover panes |
| gate-h7-drain-live-roundtrip | green | LIVE drain: a real pre-cutover tmux pane is still readable, steerable and closable |
| gate-h8-teardown-closes-the-pane | green | Teardown closes the pane on the surface that created it, and reports a close it could not do |
| gate-h9-startup-reports-unusable-herdr | green | Startup says the fleet cannot dispatch: herdr is a bootstrap tool, and a stopped server is its own problem line |
| gate-h10-busy-agent-acknowledgment | green | Acknowledgment is real for a BUSY agent, or it is reported as unconfirmed rather than claimed |
| gate-t1-severity-proceeds | green | Intake severity bar: non-blocking findings proceed with notes; a blocker, an escalate or a malformed verdict still stops the spawn |
| gate-t1-proceed-rate-nonzero | green | The council reports its own proceed rate: a structurally zero rate over a meaningful sample is a fault, not strictness |
| gate-q8-gate-classifier | frozen | Gate classifier: red AND declared is acceptable, frozen is acceptable, absence cases explicit, pure and fail-closed |
| gate-q9-verify-honours-declared-red | frozen | Quarterdeck honours gates/accepted-red.md, ahead of both models |
| gate-t1-brief-preflight-rules | green | Brief preflight rules: each rule refuses with the offender named, and the clean brief still passes |
| gate-t1-brief-preflight-spawn-gate | green | Brief preflight spawn gate: an impossible brief is refused before anything is created |
| gate-w1-herdr-stale-detected | green | A wedged herdr crewmate raises a stale wake; an idle one does not, and the fleet is read in one snapshot call |
| gate-w2-tmux-stale-unregressed | green | A wedged pre-cutover tmux crewmate still raises a stale wake, and a pre-seam meta is still read correctly |
| gate-w3-secondmate-idle-silent | green | An idle kind=secondmate herdr pane raises no stale wake, while an ordinary crewmate in the same state does |
| gate-w4-ctx-herdr-e2e | green | E2E on herdr: measure -> select -> checkpoint -> fresh handoff -> /clear -> rehydrate |
| gate-w5-ctx-herdr-busy-guard | green | Busy-guard on herdr: an over-threshold pane that is working does NOT fire |
| gate-w6-awaiting-verdict-not-stale | green | Awaiting a Quarterdeck verdict is not stale, and a rejected claim still is |
| gate-w7-afk-escalates-herdr-wedge | green | Away-mode escalates a wedged herdr crewmate instead of dropping it |
| gate-t1-merge-target-resolution | frozen | The merge target is resolved by one pure rule: named beats inferred, and more than one remote with no explicit choice is a stop |
| gate-t1-merge-repo-pinned | frozen | A merge lands in the repository that was named: the merge command carries --repo, and an ambiguous target refuses without invoking the tool |
| gate-t2-merge-foreign-host | frozen | A pull-request reference on a foreign host cannot lend its number to a repository it does not name |
| gate-t2-merge-pull-in-query | frozen | A second /pull/<n> in a url's query cannot become the pull request that is merged |
| gate-t2-merge-pull-in-fragment | frozen | A second /pull/<n> in a url's fragment cannot become the pull request that is merged |
| gate-t2-merge-trailing-path | frozen | Path segments after the pull-request number are refused, never trimmed |
| gate-t2-merge-passthrough-repo-flag | frozen | A repository flag after `--` cannot override the pin, in ANY spelling - and passthrough is an allowlist rather than a blocklist |
| gate-t2-merge-duplicate-repo-flag | frozen | A merge target is named once: a repeated target flag, or a --repo and --remote that disagree, refuses instead of letting the last one win |
| gate-t2-merge-ambiguous-remotes | frozen | A bare pull-request number in a clone with more than one remote refuses, naming every candidate, and announces no target |
| gate-t2-merge-env-redirect | frozen | GH_REPO and GH_HOST are pinned at the exec, so an environment variable cannot redirect a merge without appearing in the argv |
| gate-t2-merge-git-config-substitution | frozen | An injected git configuration cannot substitute the remote URL a merge target is resolved from, and does not pass quietly |
| gate-t2-merge-origin-proof | frozen | The resolved target must be proved equal to this clone's origin, or affirmed by a flag that names no repository |
| gate-t2-merge-argv-egress | frozen | The finished merge argv is re-read before exec and must pin the resolved target exactly once |
| gate-t4-routed-brief-reports-to-destination | frozen | A routed item's brief reports into the destination home, not the origin |
| gate-t4-handoff-safety-preserved | frozen | Routing the channel did not weaken any handoff refusal |
| gate-h11-doctrine-renders-the-constants | frozen | Doctrine: the rules are RENDERED from the constants that enforce them, never restated beside them |
| gate-h12-name-plans-then-applies-atomically | frozen | `name` plans by default and applies both slots or neither, rolling the tab back when the agent rename is refused |
| gate-h13-workspace-lookup-fails-closed | frozen | Workspace lookup fails closed: an unreadable listing refuses instead of reading as an empty fleet |
| gate-c1-helm-writer-only | green | The helm is a writer-only seam that CLAIMS: drive verbs refuse under a live foreign holder, boot paths never do |
| gate-c2-helm-take-and-isolation | green | Exclusivity under a real race, --take only against a dead holder, no redirect bypass, and a secondmate's own helm |
| gate-t4-landed-steer-not-reported-swallowed | green | A steer that landed is reported as delivered, not as a swallowed Enter |
| gate-t4-swallowed-enter-still-refused | green | A genuinely swallowed Enter is still refused: the false negative was not traded for a false positive |
| gate-t4-lens-patch-scoped-to-branch | frozen | The lens patch carries the branch's own commits and not commits that already landed |
| gate-t4-lens-patch-file-boundary-split | frozen | A payload over its bound drops whole named files and is still a valid patch |
| gate-t4-lens-patch-refuses-corrupt | frozen | A payload that is not a valid patch refuses the lens instead of being passed through |
| gate-t4-lens-patch-keeps-own-tests | frozen | The branch's own tests survive a bound that forces omission |
