## Intent

Extract the duplicated process-event arm and delivery-shim wiring into one owner after reading bin/fm-procevent-lavish.sh, bin/fm-procevent-when.sh, bin/fm-procevent-remote-reply.sh, bin/fm-watch.sh, and bin/fm-procevent.sh; do not invent a second control plane. Keep one owner for the arm-and-shim contract: register the source, bind identity, start or let reconcile start the runner, and own generated check-shim bytes. Keep adapters thin with only adapter-specific identity, argv, classify/terminal/autohandle behavior, and policy. Keep capture, publication, ownership, and handled acknowledgement in the generic runner. Do not restate the runner contract in adapters, AGENTS.md, or a second document. Keep flag and refusal mechanics in the owning script header and point other mentions at that owner. Add portable executable behavior tests under tests/ named <subject>.test.sh; never assert implementation-source bytes. Run bin/fm-lint.sh on script changes. Preserve the target captain fork bingb0t5/firstmate, do not merge, and stop if the pipeline opens a PR against kunchenguid/firstmate, retaining pipeline-fix commits and reporting the blocked outcome. The accepted review decision requires replacing the lavish adapter restatement with a pointer to the fm-procevent.sh header and updating AGENTS.md so it no longer claims state/procevent is written only by fm-procevent.sh; do not copy the runner contract into adapters or a second document.

## What Changed

- Split mixed wake queues into durable per-actor claims so Pi supervision handles eligible task rows without consuming captain-facing rows, and hide branch outcome tool rows in Calm mode.
- Centralize process-event registration, reconciliation, and delivery-shim ownership while reducing adapters to source-specific behavior.
- Suppress repeated notifications for already-reported merged PRs and keep successful deferred startup network checks silent.

## Risk Assessment

✅ Low: The arm-and-shim extraction is well-bounded, preserves adapter-specific behavior and runner-owned state transitions, and adds executable behavioral coverage without source-content-only assertions.

## Testing

The focused process-event behavior suite passed, and an end-to-end CLI transcript confirmed registration through the shared arm seam, runner startup, durable capture, wake publication, and idempotent acknowledgement. No UI changed, so screenshot evidence was not applicable.

<details>
<summary>Evidence: End-to-end process-event CLI transcript</summary>

Source: [End-to-end process-event CLI transcript](https://github.com/bingb0t5/firstmate/blob/d812fc75dfaf0280f9aac95a6e6236892f45f0e2/.no-mistakes/evidence/fm/fm-procevent-shim-extract/procevent-arm-end-to-end.txt)

```text
$ fm-procevent.sh arm lavish demo-source -- /usr/bin/printf captain-feedback
armed: demo-source (lavish)
starts on the watcher's next cycle; or run: bin/fm-procevent.sh reconcile

$ fm-procevent.sh list
SOURCE                       ADAPTER      OWNER      PENDING
demo-source                  lavish       none       0

$ fm-procevent.sh reconcile
reconciled: published=0 started=1 stopped=0 uncertain=0

$ captured result (durable inbox)
captain-feedback

$ published wake (durable queue)
check | check: procevent lavish demo-source 1

$ fm-procevent.sh handled demo-source 1
handled: demo-source 1

$ fm-procevent.sh handled demo-source 1  # idempotent repeat
already-handled: demo-source 1
```
</details>

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"dade480e6a1027de8aed1715191c2511ef10b223","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>⚠️ **Rebase** - 1 warning</summary>

- ⚠️ `.agents/skills/gnhf-companion/SKILL.md` - branch carries 2 commit(s) that exist on your local main branch but were never pushed to origin/main; rebasing would bundle this unrelated work (47 file(s)) into the PR:
- 6a2cd6c fix(pi): hide branch outcomes tool rows in Calm (#3024)
- 85d6c72 fix: safely split supervision wake handling by actor (#2953)

Push main to origin, or rebase your branch onto origin/main, before gating.

🔧 Fix applied.
1 warning still open:

- ⚠️ `.agents/skills/gnhf-companion/SKILL.md` - branch carries 2 commit(s) that exist on your local main branch but were never pushed to origin/main; rebasing would bundle this unrelated work (47 file(s)) into the PR:
- 6a2cd6c fix(pi): hide branch outcomes tool rows in Calm (#3024)
- 85d6c72 fix: safely split supervision wake handling by actor (#2953)

Push main to origin, or rebase your branch onto origin/main, before gating.
</details>

<details>
<summary>✅ **Review** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Test** - passed</summary>

✅ No issues found.
- `bash tests/fm-procevent.test.sh`
- <code>Public CLI scenario using `bin/fm-procevent.sh arm`, `list`, and `reconcile`, followed by durable inbox and wake-queue inspection and repeated `handled` acknowledgement</code>
</details>

<details>
<summary>✅ **Document** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Lint** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.
</details>

