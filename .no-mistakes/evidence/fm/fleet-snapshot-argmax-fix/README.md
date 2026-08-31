# Fleet snapshot ARG_MAX outage - test evidence

All runs drive the real captain entry points (`bin/fm-fleet-snapshot.sh --json`,
`bin/fm-fleet-view.sh`) read-only against synthetic parent homes in a temp dir.
"BEFORE" is the base commit 3364cda copy of the script, "AFTER" is HEAD 87774e3.

| file | what it shows |
| --- | --- |
| `argmax-cumulative-before-after.txt` | The reported outage: 40 registered secondmates, 40 KB status payload each. Before the fix `--json` exits 1 with zero bytes of stdout and `fm-fleet-snapshot: main inventory summary failed` (what Control renders as its error page). After the fix it exits 0 with a 12 MB valid document carrying the full payloads. |
| `fleet-view-before-after.txt` | The captain's own surface: `bin/fm-fleet-view.sh` on the same home renders nothing (exit 1) before the fix and a complete fleet board after. |
| `argmax-single-argument-before-after.txt` | 14 secondmates x 180 KB payloads. Before the fix jq dies with `Argument list too long` 28 times and the snapshot still exits 0 with the open-decision and activity-scan text silently emptied; after the fix stderr is clean and the 180 KB summaries survive. |
| `small-fleet-compat.txt` | Small-fleet compatibility: pre-fix and post-fix documents for the standard fixture home are byte-identical (20528 bytes each) once wall-clock stamps are normalized, with identical key order and task-row order. |
| `regression-fails-before-fix.txt` | The new tests fail against the pre-fix implementations (large-fleet test against 3364cda, SIGTERM test against 7504159) and pass at HEAD. |
| `sigterm-stability-25-runs.txt` | The SIGTERM regression test run 25 consecutive times, no flake. |
| `repro-fleet-snapshot-argmax.sh`, `small-fleet-compat-check.sh` | The harnesses used above (`REPO=<checkout> bash <script> <snapshot-path> <label>`). |
