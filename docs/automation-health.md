# Automation health rollup

[`bin/fm-automation-health-check.sh`](../bin/fm-automation-health-check.sh) reads the live brain registry for rollup status, a full row table, and stale-heartbeat alerts.

The `check` action retains the original rollup of source freshness age, queue age, last successful run age, retry count, open-alert count, and terminal-receipt status for each stream.

The central `automation.registry.v1` projection also exposes `manifest_id`, `owner`, `cadence`, `last_start_at`, `last_success_at`, `terminal_outcome`, `retry_count`, `correlation_id`, `heartbeat_at`, `health`, and `last_run_id`.
The `report` action prints every row as a compact table with manifest identity, owner, cadence, source freshness age, run age, heartbeat age, open failures, retry count, correlation id, last run id, and current health.
The open_failures column is 1 when health or terminal_outcome is failed or timeout, otherwise 0.
The `run` action reads only `GET /v1/automations` and never starts, retries, completes, or polls an automation source.

The registry response is either an array or an object with an `automations` array.

Each projection uses `id`, `source_freshness_age_seconds`, `queue_age_seconds`, `last_success_age_seconds`, `retry_count`, `open_alerts`, and `last_terminal_receipt`.

The receipt is valid only when its `type` is `automation.run.receipt.v1`, `terminal` is `true`, and `status` is `success` or `succeeded`.

The rollup is green only when every required metric is present, every stream has a valid terminal receipt, and no stream has open alerts.

An n8n execution count is never treated as a successful run.

The check reads `FM_AUTOMATION_REGISTRY_URL` or `BRAIN_URL`, and reads `FM_AUTOMATION_REGISTRY_TOKEN` or `BRAIN_TOKEN` from the environment or the local `FM_AUTOMATION_REGISTRY_ENV_FILE` fallback.

Credential values are sent only as an HTTP authorization header and never appear in script output, diagnostics, or lifecycle responses.

The `start`, `heartbeat`, and `complete` actions call the existing registry lifecycle endpoints.

The `complete` action sends an `automation.run.receipt.v1` terminal receipt and does not schedule or execute the source.

The armed `secret-parity` check is one stream example.

Arm both checks when the home should monitor deployment parity and registry health:

```sh
FM_HOME=/path/to/firstmate-home bin/fm-secret-parity-check.sh arm
FM_HOME=/path/to/firstmate-home bin/fm-automation-health-check.sh arm
```

The secret-parity check remains the source check for host-local secret stores.

The health rollup observes its registry projection and does not create a parallel n8n scheduler.

A reachable empty registry reports green with no streams.

Stale detection compares row age against manifest cadence plus grace; `run` and the armed `check` path emit one captain-readable alert per new fingerprint.
Stale age uses `heartbeat_at` when present, otherwise `last_start_at`; the report heartbeat_age column uses `heartbeat_at` only.
Rows with a terminal outcome or health `failed`/`timeout` are excluded because they are no longer active heartbeat runs.
Watcher arming, polling, stale-alert deduplication, interval settings, grace, alert format, and fingerprint format are documented in [`docs/configuration.md`](configuration.md) "Automation health rollup".
