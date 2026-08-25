## CEO overview

- **What is changing:** Bearings gains a backward-compatible read-only board that combines the main home and registered secondmate homes in one validated view.
- **Why it matters:** The captain can see exact ownership, work stage, pull eligibility, freshness, validity, and each home's independent attention count without relying on parent status prose.
- **Customer or business impact:** Valid homes stay fully usable, while invalid or timed-out homes are unmistakably unavailable and cannot dispatch work.
- **Risk and rollout:** The board rejects malformed v2 data before replacing the stable page and continues to render v1 data for one release, limiting rollout risk.

## What changed technically

The Bearings snapshot projects the accepted v2 fields without changing fleet snapshot production, attention counting, pull execution, handoff, spawn enforcement, backlog mutation, or adding a service.
The board validates v2 owner-local task identity, disables actions for unavailable homes and secondmate-owned cards, and retains existing captain-answer, retry/fix, and guarded merge bindings.
Public-interface coverage exercises stage transitions, independent domain counts, partial failure, inventory contradiction, missing and unknown states, secondmate action refusal, malformed-v2 stable-file preservation, and v1 compatibility.

## Validation

- **Checks passed:** `bash tests/fm-bearings-board.test.sh`; `bash tests/fm-bearings-snapshot.test.sh`; repository CI checks other than the two PR-description checks.
- **Checks not run:** No additional validation phase was run in this assigned CI repair phase.
- **Evidence and limitations:** Representative v1 and v2 real builds and laptop renders are linked in the existing PR evidence; the earlier Chrome bridge lacked a page ID, so the recorded screenshot inspection used installed headless Chrome.

Current module retained: The read-only projection remains in `bin/fm-bearings-snapshot.sh` and rendering remains in `bin/fm-bearings-board.sh`; no new board service or task database was introduced.

## Module-boundary decision

Retain the current script boundaries because fleet snapshot production remains authoritative and the Bearings scripts only project, validate, and render that contract.

## Decision needed

No decision required.
