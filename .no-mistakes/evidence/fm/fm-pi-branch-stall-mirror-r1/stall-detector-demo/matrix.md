# Cadence-aware stall detector — operator checkpoint matrix

Parent watcher is `bin/fm-watch-checkpoint.sh`. The page line is `check: secondmate wake-loop stalled: mate=… row=…`. Quiet checkpoints print `checkpoint: no actionable wake within 2s` and leave the parent wake queue empty. Mate foreign queues stayed byte-stable (read-only).

| Case | Recorded state | Pane text | Age | Expected | Observed | Result |
| --- | --- | --- | --- | --- | --- | --- |
| 01-grok-175s-waiting-quiet | harness=grok | `Waiting for background command` | 175s | quiet | quiet (no page) | **PASS** |
| 02-grok-175s-ready-quiet | harness=grok | `ready>` | 175s | quiet | quiet (no page) | **PASS** |
| 03-grok-250s-ready-page | harness=grok | `ready>` | 250s | PAGE | PAGED parent | **PASS** |
| 04-grok-120s-stale-beacon-page | harness=grok, beacon 400s stale | `Waiting for background command` | 120s | PAGE | PAGED parent | **PASS** |
| 05-pi-274s-ready-quiet | harness=pi | `ready>` | 274s | quiet | quiet (no page) | **PASS** |
| 06-pi-400s-waiting-page | harness=pi | `Waiting for background command` | 400s | PAGE | PAGED parent | **PASS** |
| 07-pi-400s-live-claim-quiet | harness=pi, live branch grant for seq 7 | `ready>` | 400s | quiet | quiet (no page) | **PASS** |
| 08-pi-400s-dead-claim-page | harness=pi, dead grant leftover | `ready>` | 400s | PAGE | PAGED parent | **PASS** |
| 09-lease-steer-no-regression | branch grant of seq 2-3; main owns seq 1 | n/a | n/a | main row survives branch ack | lease/grant intact | **PASS** |

Detection is from recorded `harness=` / live Pi branch grant, not pane text:

- Grok 175s stays quiet with either `Waiting for background command` or `ready>`.
- Pi 400s pages even when the pane says `Waiting for background command`.
- A live Pi claim stays quiet past the claim window; a dead grant cannot hide that stall.
