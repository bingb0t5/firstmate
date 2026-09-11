# Deployment secret parity runbook

This runbook describes the release preflight and repair procedure for the approved deployment variable tuples.
The [`fm-secret-parity-check.sh`](../bin/fm-secret-parity-check.sh) header and `--help` output are the source of truth for tuple membership, provider resources, and comparison mechanics.
This runbook is the source of truth for ownership, rotation order, rollback, and verification.
Never place variable values, hashes, fingerprints, or value-derived strings in this runbook, a pull request, or a status line.

## Release preflight

Run the preflight immediately before declaring a release healthy:

```sh
FM_SECRET_PARITY_COOLIFY_ENV_FILE=/path/to/coolify.env \
FM_SECRET_PARITY_RENDER_ENV_FILE=/path/to/render.env \
bin/fm-secret-parity-check.sh preflight
```

The command exits successfully only after every required variable is present and equal across its approved environments.
A missing variable, an empty variable, a mismatched variable, a failed provider read, or a timed-out sweep returns a non-zero result.
The output names only the variable and environment labels that need attention.
Do not treat a provider-unavailable result as a healthy release.
Coolify values with one matching quote layer are normalized by the script before comparison.

## Approved tuples

Each row has one owner and one source of truth.
The source of truth is never a repository file.

| Variable | Approved environments | Owner | Source of truth | Rotation order | Rollback | Verification |
| --- | --- | --- | --- | --- | --- | --- |
| `BEANBOT_PLATFORM_SYNC_TOKEN` | `admin-prod`, `admin-staging`, `signals`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `admin-staging` -> `signals` -> `render-llalo` | Restore the last-known-good value from the secured operator record to the updated environments in reverse order, then leave the source of truth at that value. | Run `preflight` and confirm this variable is absent from the failure list. |
| `LALO_ASSISTANT_API_KEY` | `admin-prod`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `render-llalo` | Restore the last-known-good value from the secured operator record to `render-llalo`, then to `admin-prod` if the source changed. | Run `preflight` and confirm this variable is absent from the failure list. |
| `PLATFORM_SUPABASE_URL` | `admin-prod`, `admin-staging`, `signals`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `admin-staging` -> `signals` -> `render-llalo` | Restore the last-known-good source value to the updated environments in reverse order. | Run `preflight` and confirm this variable is absent from the failure list. |
| `PLATFORM_SUPABASE_SERVICE_ROLE_KEY` | `admin-prod`, `admin-staging`, `signals`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `admin-staging` -> `signals` -> `render-llalo` | Restore the last-known-good value from the secured operator record to the updated environments in reverse order, then leave the source of truth at that value. | Run `preflight` and confirm this variable is absent from the failure list. |
| `STRIPE_SECRET_KEY` | `admin-prod`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `render-llalo` | Restore the last-known-good value from the secured operator record to `render-llalo`, then to `admin-prod` if the source changed. | Run `preflight` and confirm this variable is absent from the failure list. |
| `STRIPE_WEBHOOK_SECRET` | `admin-prod`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `render-llalo` | Restore the last-known-good value from the secured operator record to `render-llalo`, then to `admin-prod` if the source changed. | Run `preflight` and confirm this variable is absent from the failure list. |
| `STRIPE_PAID_BETA_PRICE_ID` | `admin-prod`, `render-llalo` | Platform operations | `admin-prod` variable | `admin-prod` -> `render-llalo` | Restore the last-known-good source value to `render-llalo`, then to `admin-prod` if the source changed. | Run `preflight` and confirm this variable is absent from the failure list. |
| `BRAIN_TOKEN_N8N` | `n8n`, `brain` membership list | Brain integration owner | `brain` `BRAIN_TOKENS` membership list | Add the replacement membership to `brain`, update `n8n`, verify, then remove the retired membership from `brain`. | Restore the last-known-good membership and consumer configuration, verify membership, then rerun `preflight`. | Run `preflight` and confirm the n8n token is a member of the brain token list. |

The fixed `signals` pins `LALO_APP_API_URL` and `LALO_DIRECTORY_MATCH_URL` are also release preflight requirements, but they are not rotating tuples.
Their expected values and comparison rules remain owned by the script header.

## Repair procedure

1. Run `preflight` and record only the variable names and environment labels it reports.
2. Notify the row owner and use the row's source of truth to determine the intended value without copying it into a repository, pull request, or status line.
3. Apply the row's rotation order through the approved provider access.
4. Run `preflight` again before restarting or declaring any affected service healthy.
5. If verification fails, stop the release and follow that row's rollback order.
6. After rollback, run `preflight` again and retain only the value-free result as release evidence.

A successful `check` alert is a detection signal, not release approval.
Only a successful `preflight` result may be used as the shared-variable health decision.
