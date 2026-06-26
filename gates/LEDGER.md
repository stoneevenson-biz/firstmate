# Gate Ledger

## Drain list (6)

- [ ] gate-g1-threshold — Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not (red) **ready**
- [ ] gate-g2-busy-guard — Busy-guard: an over-threshold pane that is busy does NOT fire (red) **ready**
- [ ] gate-g3-rehydrate — Rehydrate: SessionStart with handoff injects+archives it; no-handoff path unchanged (red) **ready**
- [ ] gate-g4-e2e — E2E on scratch pane: threshold -> checkpoint -> handoff -> /clear -> rehydrate (red)
- [ ] gate-g5-inject-cap — Inject cap: handoff under 10k injected verbatim, over 10k yields a pointer (red) **ready**
- [ ] gate-g6-managed-scope — Managed-scope: only firstmate-session panes are selected; ad-hoc/personal panes skipped (red) **ready**

## All gates

| id | status | title |
| --- | --- | --- |
| gate-g1-threshold | red | Threshold selection: captain>=185k and crew>=50% selected; sub-threshold not |
| gate-g2-busy-guard | red | Busy-guard: an over-threshold pane that is busy does NOT fire |
| gate-g3-rehydrate | red | Rehydrate: SessionStart with handoff injects+archives it; no-handoff path unchanged |
| gate-g4-e2e | red | E2E on scratch pane: threshold -> checkpoint -> handoff -> /clear -> rehydrate |
| gate-g5-inject-cap | red | Inject cap: handoff under 10k injected verbatim, over 10k yields a pointer |
| gate-g6-managed-scope | red | Managed-scope: only firstmate-session panes are selected; ad-hoc/personal panes skipped |
