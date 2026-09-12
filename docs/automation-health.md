# Automation health rollup

[`bin/fm-automation-health-check.sh`](../bin/fm-automation-health-check.sh) gives Firstmate one compact status line for every automation projection in the live brain registry.

The rollup reports source freshness age, queue age, last successful run age, retry count, open-alert count, and terminal-receipt status for each stream.

The registry response is either an array or an object with an `automations` array.

Each projection uses `id`, `source_freshness_age_seconds`, `queue_age_seconds`, `last_success_age_seconds`, `retry_count`, `open_alerts`, and `last_terminal_receipt`.

The receipt is valid only when its `type` is `automation.run.receipt.v1`, `terminal` is `true`, and `status` is `success` or `succeeded`.

The rollup is green only when every required metric is present, every stream has a valid terminal receipt, and no stream has open alerts.

An n8n execution count is never treated as a successful run.

The check reads `FM_AUTOMATION_REGISTRY_URL` or `BRAIN_URL`, and reads `FM_AUTOMATION_REGISTRY_TOKEN` or `BRAIN_TOKEN` from the environment or the local `FM_AUTOMATION_REGISTRY_ENV_FILE` fallback.

Credential values are sent only as an HTTP authorization header and never appear in rollup output, diagnostics, or lifecycle responses.

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

Watcher arming, polling, deduplication, and interval settings are documented in [`docs/configuration.md`](configuration.md) "Automation health rollup".
