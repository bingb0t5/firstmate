Local test phase for CI cost reduction

- Compared base 757f81d525d912ad27b4fe22f89bb8304376a9ab with target 63582e24f7f567ca49f1342ccbc1e9e3bc146a43.
- Ran `bash tests/pr-communication.test.sh` successfully.
- Generated a temporary selector harness from the definitions in `tests/fm-inactive-reconcile.test.sh`, preserving its original assertions and replacing only its final all-tests invocation list with these existing scenarios:
  - `test_unbounded_candidate_evidence_is_partial_and_non_escalating`
  - `test_partial_candidate_remains_in_resumable_regular_sweep`
  - `test_active_due_work_precedes_declared_wait_reconciliation`
- Executed `bash tests/.ci-cost-timing-evidence.sh`. Its reporting function emitted the dynamically scoped elapsed value, the produced partial-coverage record, capacity-marker absence, and child-state read log. All three scenarios passed. The temporary harness was removed after use.
- The timing scenario measured 3 seconds against the required <=4 bound. The historical >3-second flake was not reproduced on this host.
- Ran `python3 /home/rich/.no-mistakes/evidence/01M1ZA6ZNPH4XW1J1Z0FXTS1S1/workflow-behavior.py`. Initial harness errors concerning non-PR workflows and absent PR data on push events were corrected before the successful final run.
- `workflow-behavior.log` contains the normalized event/concurrency model, before/after PR workflow counts, strict configuration parsing, and actual workflow shell-command output for valid and invalid PR bodies.
- Workflow scheduling is local semantic evidence. No GitHub workflow was triggered or monitored, and notification delivery and billed minutes were not measured. Remote CI and merge remain the outer executor's phases.
- No UI was changed. No lint, static-analysis, full repository suite, pipeline-control, push, or merge commands were run.
