## CEO overview

- **What is changing:** `fm-send.sh` now accepts an explicit `--inbox-only` option. A caller using that option can submit slash-prefixed or dollar-prefixed text as a durable inbox message without placing that text into the worker's command-aware terminal composer.
- **Why it matters:** Browser and third-party callers should not have to inspect untrusted message text to determine whether the harness might treat it as a command. The caller can select the data plane explicitly.
- **Customer or business impact:** This creates the safety boundary needed for Firstmate Control to restore its composer separately. This change does not re-enable that UI.
- **Risk and rollout:** The option is additive. Existing callers retain the previous content-shaped routing, while callers that opt in get durable inbox delivery. Focused tests and the end-to-end transcript cover the old and new paths for both risky prefixes.

## What changed technically

- Added `--inbox-only` parsing for task selectors resolved through the active Firstmate home's metadata.
- Routed opt-in text through the existing durable inbox serializer and constant doorbell path.
- Kept slash commands and Codex dollar invocations on the typed plane when the option is absent.
- Added focused executable tests for slash-prefixed and dollar-prefixed bodies.

## Validation

- **Checks passed:** `bash tests/fm-send-inbox.test.sh`; a manual base-versus-target end-to-end exercise of the real `bin/fm-send.sh` executable; and the real PR communication checker against this narrative.
- **Checks not run:** The complete repository suite, linters, formatters, static analysis, remote CI, and the disabled Firstmate Control composer were not run in this targeted test phase.
- **Evidence and limitations:** `fm-send-inbox-only-e2e/transcript.txt` shows base and target defaults typing both prefixes, while target opt-in calls persist the exact body and type only the constant doorbell. The terminal endpoint was a deterministic boundary recorder rather than a live agent harness, which isolates whether untrusted bytes cross into the command-aware composer. The Control UI is deliberately out of scope.

## Module-boundary decision

Current module retained: message-plane selection belongs in `bin/fm-send.sh`, where target identity, harness type, typed delivery, and durable inbox delivery are already resolved. No new routing component is needed.

## Decision needed

No decision required.
