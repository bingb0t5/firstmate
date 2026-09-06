## CEO overview

- **What is changing:** Extract the duplicated process-event arm and delivery-shim wiring into one owner after reading bin/fm-procevent-lavish.sh and bin/fm-procevent.sh; do not invent a second control plane.
- **Why it matters:** Keep one owner for the arm-and-shim contract and never assert implementation-source bytes.
- **Customer or business impact:** Preserve the target captain fork, do not merge, and stop if the pipeline opens a PR against the wrong remote.
- **Risk and rollout:** Add portable executable behavior tests under tests/named-subject.test.sh.

## What changed technically

- Split mixed wake queues into durable per-actor claims.

## Validation

- **Checks passed:** Unit tests and type check.
- **Checks not run:** End-to-end test was not run locally.
- **Evidence and limitations:** Tested with a representative request.

## Module-boundary decision

Current module retained: process-event registration stays with the existing owner.

## Decision needed

No decision required.
