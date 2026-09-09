# Live-run classification test evidence

Tested target: `fdfb14dce3e3b934aa300bebfe6594ea23bc9fea`.
Compared classifier: `1b670148d987147261d8617e5194c35dab54302e`.

The public `bin/fm-crew-state.sh` interface was exercised with the existing `tests/fm-crew-state.test.sh` fake no-mistakes harness and real disposable Git repositories.
The resulting classification was then consumed by the real `bin/fm-inactive-reconcile.sh scan --startup` command.
No live Lalo task or no-mistakes daemon was changed or queried.

- Initiating trigger: the active same-branch run reports pipeline-owned commit `44b15c94`, which cannot be resolved in the local task repository.
- Masking condition: an older failed runs-list row still matches the local HEAD and branch, so the old classifier falls back to that historical failure.
- Visible symptom: the public classifier says `state: failed`, and reconciliation creates a persisted `fm-terminal-outcome.v1` presentation record for `lalo-launch-offers-member-billing`.

After the fix the same inputs produce `state: parked` with the current review findings and no terminal record.
The unrelated overdue-progress notification still appears because the fixture deliberately has an aged, untimestamped working event; this is existing nonterminal supervision behavior.

The observed incident's local `44ffc0a3` is represented by a real deterministic fixture commit `d34eee05f7f8ccb92488e3892c2a6f6afb64fbe2`.
Both before and after checks use that same local commit, and the historical row names its actual short SHA.
This preserves the exact head-binding relationship without claiming to possess the live Lalo repository or its historical objects.
The unavailable pipeline SHA remains the observed `44b15c94` and its absence is checked with Git before classification.

The existing regression assertion fails against the pre-fix classifier and passes against the target.
The proven same-branch path, where a locally available pipeline fix commit descends from local HEAD, continues to report working.
The new exception accepts unavailable heads only for running, fixing, ci, awaiting_approval, and fix_review statuses.
Completed, failed, cancelled, passed, and checks-passed unavailable-head cases use current local status instead.
Existing behavioral checks also reject available rewritten history, local advancement past the run, and missing heads.

The transcript includes CLI inputs, public outputs, the pre-fix persisted terminal record, and the absence of that record after the fix.
The shell evidence script extracts fixture definitions without asserting implementation text, then executes public interfaces and asserts their outputs and persisted state.
An initial evidence-driver attempt reused the regression fixture directory and emitted a branch-already-exists setup error; the pre-fix fixture was isolated and the complete evidence check was rerun successfully.

No rendered UI is involved, so the CLI transcript and persisted record are the end-user evidence.
Lint, workflow validation, delivery, PR actions, and CI are owned by the outer executor and were not run in this test phase.
