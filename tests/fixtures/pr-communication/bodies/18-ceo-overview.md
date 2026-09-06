## CEO overview

- **What is changing:** Firstmate gains one authenticated, read-only HTTP endpoint that exposes its existing fleet snapshot to the Lalo server adapter.
- **Why it matters:** Lalo can consume Firstmate's operational truth without copying fleet state or gaining Firstmate mutation authority.
- **Customer or business impact:** This enables the already-built Lalo Fleet UI to receive live upstream data once an operator configures the URL and server-only Bearer token.
- **Risk and rollout:** The service binds to loopback by default, requires an explicit absolute `FM_HOME`, rejects all non-GET requests, never logs the token, and returns a generic unavailable response for producer failure, timeout, oversized output, or invalid schema.

## What changed technically

- Added `bin/fm-fleet-snapshot-serve.py`, a standard-library foreground service at `GET /api/fleet/snapshot`.
- The service invokes only `bin/fm-fleet-snapshot.sh --json`, bounds runtime and output, validates `fm-fleet-snapshot.v1`, and projects the typed fields expected by Lalo PR 352 without reading Firstmate files independently.
- Added executable HTTP behavior coverage for authentication, method and path refusal, canonical invocation and `FM_HOME` propagation, loopback default, secret non-disclosure, failures, timeout, and schema refusal.
- Documented the service in `docs/scripts.md` and the executable help/header.

## Validation

- **Checks passed:** Real local end-to-end request against the wrapper and real canonical producer: missing authentication returned 401, wrong authentication returned 401, non-GET returned 405, correct authentication returned 200 with schema `fm-fleet-snapshot.v1` and the Lalo adapter fields; `bin/fm-test-run.sh tests/fm-fleet-snapshot-serve.test.sh tests/fm-fleet-snapshot-view.test.sh`; `bin/fm-lint.sh`; `shellcheck -x --shell=bash --severity=style tests/fm-fleet-snapshot-serve.test.sh`; `python3 -m py_compile bin/fm-fleet-snapshot-serve.py`; `bin/fm-doc-audience-check.sh`; `git diff --check`.
- **Checks not run:** CI, deployment, merge, no-mistakes, and Lalo repository tests were not run because this direct-PR task stops before merge and does not modify Lalo.
- **Evidence and limitations:** The local real-producer proof used a temporary empty operational home and retained only sanitized HTTP results. Focused tests use a disposable adjacent producer to exercise failure and timeout boundaries while the real-producer proof exercises the actual canonical engine.

## Module-boundary decision

Current module retained: the new service is only an authenticated transport and typed projection over `bin/fm-fleet-snapshot.sh`; Firstmate's canonical producer remains the sole fleet aggregation and authority.

## Decision needed

No decision required.

