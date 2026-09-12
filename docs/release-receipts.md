# Release and migration receipts

[`bin/fm-release-receipt-check.sh`](../bin/fm-release-receipt-check.sh) observes an already-authorized Coolify or Render release and records whether the deployed build and App DB migration receipt match the intended commit.

The utility never starts, restarts, reconfigures, resizes, or rolls back a live service.
It never reads a deploy or start endpoint.
The `check` action performs one bounded observation.
The `run` action repeats the same read-only observation until the receipt is complete or its timeout expires.
The `audit` action prints the current receipt and exits nonzero unless the release is complete.
The `arm` action registers `check` with the existing firstmate watcher.

## Manifest

Set `FM_RELEASE_SPEC_FILE` to a JSON manifest, or place the default manifest at `config/release-receipt.json` in the firstmate home.
The manifest requires `release_id`, `intended_commit`, at least one `targets` row, and at least one migration.
Each target requires `provider`, `expected_build_id`, and either a provider identifier or an explicit `status_url`.
An optional `expected_commit` overrides the manifest `intended_commit` for that target only.
Each migration is either a name string or an object with `name` and an optional `commit`.

The following manifest represents the 2026-09-12 admin production cut without making that cut a special case:

```json
{
  "release_id": "admin-prod-2026-09-12",
  "intended_commit": "ada46a5dda0a1d654c29acf82a6db20d8296c407",
  "targets": [
    {
      "provider": "coolify",
      "app_id": "ga48pn39tt4b9bswgsuaqu7v",
      "build_id_url": "https://admin.laloapp.co/api/build-id",
      "expected_build_id": "dev-mty0b1u3"
    }
  ],
  "migrations": [
    "20260912120000_checkin_anomaly_review_items.sql",
    "20260912130000_whats_on_editor_decision_exceptions.sql"
  ],
  "ledger": {
    "project_ref": "evvrlbeilubeggmrhjgs",
    "name_field": "name",
    "commit_field": "commit_sha"
  }
}
```

The previous live commit can remain incident evidence or a rollback reference, but it is not an accepted commit for a new manifest unless explicitly selected as `intended_commit`.
A Render target uses `service_id` and optional `deploy_id` instead of `app_id`.
Provider-specific status and build paths already used by an operator can be supplied as `status_url` and `build_id_url`.
A `build_id_url` response may be plain text or JSON with a `build` or `build_id` field.

## Credentials and ledger sources

Coolify credentials use the existing `~/.config/beanz/coolify.env` store.
Render credentials use the existing `~/.config/lalo/render-api.env` store.
The App DB bearer is read from an existing operator environment or the path named by `FM_RELEASE_APP_DB_ENV_FILE`.
The existing App DB names `LALO_APP_SUPABASE_URL` and `LALO_APP_SUPABASE_SERVICE_ROLE_KEY` take precedence over generic `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` fallbacks.
Explicit `FM_RELEASE_APP_DB_URL` and `FM_RELEASE_APP_DB_TOKEN` overrides retain precedence.
The utility does not create a new credential store or copy credential values into the manifest.
Request headers are supplied to curl through stdin, with curlrc configuration disabled, so bearer values do not appear in curl command arguments or configured traces.

The ledger defaults to the existing Supabase REST table `public.lalo_app_migration_ledger` for project ref `evvrlbeilubeggmrhjgs`.
An existing worker-1 workflow may provide a read-only JSON ledger file through `ledger.file` when that is the established path for the home.
No worker, scheduler, or release control plane is created by this check.
Every matching ledger row must have `status: "applied"`, following the existing App DB ledger semantics.
Rows marked `unapplied` or `unknown`, or with a missing/null status, are missing applied receipts and remain unverified.
The default name lookup accepts the established `filename` column as well as `name`; an optional migration commit expectation must also match the configured commit field.
These row requirements also apply to an existing worker's `ledger.file` input; a saved snapshot does not establish fresh deployment evidence.

## Audit result

The durable receipt is `state/.release-receipt`.
It contains the intended commit, observed provider status, observed build id, migration names, and a redacted outcome.
It never contains provider credentials.

`app=healthy migration=verified` is the only complete result.
`app=healthy migration=unverified` means the application is live at the intended build but the migration receipt is missing or unavailable.
`waiting` means deployment or migration receipt evidence is not yet observable.
During rollout, a provider status that looks complete before the deployed commit is an observable SHA stays waiting rather than mismatch.
A stale build id also stays waiting until the commit is observable, and again while the commit already matches `intended_commit` but the build id has not yet caught up.
Coolify's `running:healthy` status is accepted only when the independent intended commit and build checks match.
`mismatch` is reported only once the observable commit or build id definitively differs from the manifest, or when deployment status or migration commit evidence conflicts.
The audit action prints the current result and exits nonzero unless the complete result is present.

Use the watcher check for ongoing observation:

```sh
FM_HOME=/path/to/firstmate-home \
FM_RELEASE_SPEC_FILE=/path/to/release-receipt.json \
FM_RELEASE_APP_DB_ENV_FILE=/path/to/existing/lalo-admin/.env \
bin/fm-release-receipt-check.sh arm
```

`arm` resolves relative manifest and App DB env-file paths against the arming working directory and preserves their absolute paths in the registered shim.
The input directories must exist when arming.
Only the nonsecret env-file selector is persisted; credentials are read from the existing store on each execution.
Environment-only credential overrides are not serialized into the shim.
Use the existing operator env-file selector when the watcher must work independently of the shell that armed it.
After changing an input path, re-arm through this command rather than editing generated shim bytes.

Use `run` when a release operator needs a bounded wait for completion.
`FM_RELEASE_TIMEOUT_SECS` (default 900) bounds the wait, and `FM_RELEASE_POLL_SECS` (default 10) sets the poll interval.
The script header and `--help` output own the remaining manifest and environment fields.

```sh
FM_HOME=/path/to/firstmate-home \
FM_RELEASE_SPEC_FILE=/path/to/release-receipt.json \
FM_RELEASE_APP_DB_ENV_FILE=/path/to/existing/lalo-admin/.env \
bin/fm-release-receipt-check.sh run --timeout 900
```

## Member release input

For a Render member release, the release owner supplies `release_id`, the intended commit SHA, the expected build id, the exact expected migrations and their ledger project, and the intended deploy id.
Place the service and deploy identifiers in the target's `service_id` and `deploy_id`, with the independently observed build endpoint in `build_id_url` when needed.
Supply per-migration commit expectations only when the ledger records that evidence.
Do not derive intended release identity from whichever build happens to be in production.
The check observes the owner-selected release; it does not authorize or trigger a deployment.
