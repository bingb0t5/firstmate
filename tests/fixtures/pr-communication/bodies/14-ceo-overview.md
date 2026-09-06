<!-- Write this for a non-programmer CEO. Be specific, plain spoken, and concise. -->
<!-- Shared template. Canonical copy: lalo-platform/.github/PULL_REQUEST_TEMPLATE.md - edit there first, then sync every repo copy identically. -->

## CEO overview

- **What is changing:** Firstmate can now identify and start the next assigned task in a local queue, while enforcing a fixed limit of four active workers in each home.
- **Why it matters:** Work is claimed in a predictable order, missing priorities stop safely, and concurrent starts cannot silently exceed the local capacity limit.
- **Customer or business impact:** Domain mates can consume routed work reliably without duplicate claims, hidden overload, or nested manager structures.
- **Risk and rollout:** This changes how work is selected and started, so uncertain conditions stop safely. The rollout is covered by queue, simultaneous-start, handoff, runtime, macOS Bash, and secondmate lifecycle tests; no automatic data conversion or merge is included.

## What changed technically

- Added `bin/fm-pull.sh` with `ready` and `start` operations, deterministic priority/date/ID ordering, and same-task reservation recovery.
- Added bounded local attention and pull facts to `bin/fm-fleet-snapshot.sh`, plus a hard four-worker backstop shared by pull, direct spawn, and batch spawn paths.
- Required priorities across local and remote backlog handoff, including dependency-closed moves, while preserving receiver-owned queue consumption.
- Prevented secondmate homes from seeding or spawning nested secondmates and updated the owning skills and documentation.
- Applied CI fixes for stock macOS Bash array handling, fail-closed inventory fixtures, runtime cleanup ordering, and nested-secondmate validation order.
- Exact final diff against `e5025d3a3a01430baa54316357892c234321e1d7`: 21 files, 949 insertions, 134 deletions. Exact PR head: `43e9e06c6643dd4c520fb0a4d200f917d00daa85`.

## Validation

- **Checks passed:** Lint; no-mistakes source gate; coverage guard; repository invariants; portable parallel 1 and 2; portable serial 1, 2, and 3; Herdr behavior; stock macOS Bash snapshot compatibility; behavior timing aggregate. Focused pull, spawn, handoff, secondmate lifecycle, and safety suites also passed in the pipeline.
- **Checks not run:** None intentionally omitted. The current portable serial 4 job was cancelled and remains subject to the existing same-run gate before completion.
- **Evidence and limitations:** This metadata-only update changes no source and is bound to exact head `43e9e06c6643dd4c520fb0a4d200f917d00daa85`. The communication and source-of-truth checks were failing because the prior body did not use the current required template; they must pass on this body, and every required code lane must be green before delivery.

## Module-boundary decision

Current module retained: snapshot owns local queue and attention facts, the new narrow `fm-pull.sh` CLI owns claim/start behavior, and spawn, handoff, and secondmate lifecycle guards remain in their existing owners. No additional control plane, daemon, database, or shared claim service was introduced.

## Decision needed

No decision required.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"43e9e06c6643dd4c520fb0a4d200f917d00daa85","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"completed"},{"step":"ci","status":"awaiting_approval"}]} -->

