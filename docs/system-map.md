# System map and drift score

[`bin/fm-system-map.sh`](../bin/fm-system-map.sh) builds one redacted map from the declared automation manifests, the live automation registry, repository workflow exports, the host inventory, and the live n8n workflow comparison.

The map is a read-only report.

It reuses the automation registry and the X-05 n8n operations command from `mrbeanz-brains`.

It does not schedule, execute, import, activate, or delete an automation.

## Inputs

The operator home supplies these local JSON files.

`FM_SYSTEM_MAP_MANIFEST_FILE` defaults to `$FM_HOME/config/system-map-manifests.json`.

`FM_SYSTEM_MAP_HOST_INVENTORY_FILE` defaults to `$FM_HOME/config/host-inventory.json`.

The manifest file is either an array or an object with a `manifests` array.

Each manifest identifies `manifest_id`, `manifest_version`, `owner`, `cadence`, and optionally `host_id`.

The host inventory is either an array or an object with a `hosts` or `inventory` array.

Each host identifies `id` or `host_id`, and reports a healthy `status` plus `reachable: true`.

The registry URL and bearer token resolve the same way as the automation health rollup (`FM_AUTOMATION_REGISTRY_URL`, `BRAIN_URL`, token settings, and `FM_AUTOMATION_REGISTRY_ENV_FILE`).

The registry response may be an array or an object with an `automations` or `data` array.

The registry's manifest identity, owner, cadence, host, health, and terminal outcome are compared with the declaration.

Registry outcomes must be healthy and successful for the daily score to pass.

`FM_SYSTEM_MAP_REPO` defaults to `$FM_HOME/projects/mrbeanz-brains`.

The repository must contain the checked-in `n8n/*.json` exports.

The X-05 comparison reads `/home/rich/.config/beanz/n8n.env` through `scripts/n8n-ops.ts`.

The n8n API key is never read by the system-map script and is never included in a report.

`FM_SYSTEM_MAP_N8N_COMPARISON_FILE` can provide a previously generated X-05 comparison for offline validation.

## Engineering Radar

The latest `reports/weekly-YYYY-MM-DD.md` under `FM_ENGINEERING_RADAR_ROOT` supplies the `changed_this_week` section.

The default radar root is `/home/rich/dev/engineering-radar`.

The map records the report path, report date, SHA-256, section headings, and a bounded excerpt as provenance.

A missing or older-than-eight-day weekly report fails the daily score instead of presenting an unsourced change list.

## Commands

Build the map and print a notification line only when the result changes.

```sh
FM_HOME=/path/to/firstmate-home bin/fm-system-map.sh check \
  --output-json /path/to/report/system-map.json \
  --output-markdown /path/to/report/system-map.md
```

Print the daily score and return nonzero when any source disagrees.

```sh
FM_HOME=/path/to/firstmate-home bin/fm-system-map.sh score
```

Arm the existing watcher with the read-only check when the home should monitor daily drift:

```sh
FM_HOME=/path/to/firstmate-home bin/fm-system-map.sh arm
```

Watcher arming, polling, deduplication, and interval settings are documented in [`docs/configuration.md`](configuration.md) "System map".

The JSON report has schema `firstmate.system-map.v1`.

Its `score.status` is `pass` only when all five evidence sources are present and no cross-source finding exists.
