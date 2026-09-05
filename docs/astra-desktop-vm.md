# Astra desktop VM integration

This page defines the platform-side contract for an isolated guest desktop that Infra Ops provisions and owns.

## Boundary and ownership

Infra Ops owns the VM, guest operating system, authenticated reachability, desktop lifecycle, resource limits, backup, restore, and operator viewing instructions.

Firstmate Platform owns the guest-scoped Codex CLI/Astra adapter contract, serialized desktop calls, explicit human handoff, and executable acceptance tests.

The initial callable target is Codex CLI/Astra in the guest.

This integration does not create a VM, change host networking or RDP display `:10`, copy host credential stores, or provide a Pi MCP bridge or private Desktop-app orchestration bridge.

The guest must not mount the host home, fleet credentials, production repositories, Docker socket, or other privileged host interfaces.

## Infra-to-platform readiness contract

Infra publishes one JSON readiness manifest to the guest-side operator workflow.

The manifest uses `schema: 1` and contains these fields.

- `vm.id` is the stable isolated VM identity.
- `vm.guest_user` is the non-root desktop and tool user.
- `reachability.endpoint` is the private endpoint or name used by the guest adapter.
- `reachability.transport` names the transport, such as authenticated SSH or a private tunnel.
- `reachability.auth_method` names the authentication mechanism without including a token, password, cookie, key, or other credential value.
- `reachability.authenticated` is `true` only after the operator has verified access.
- `reachability.public` is always `false` for this integration.
- `desktop.display` is the guest display identity, including its `DISPLAY` value where applicable.
- `desktop.viewer` identifies the authenticated observation and takeover method.
- `desktop.browser_profile` is the dedicated guest browser profile used by visual and DOM/CDP tools.
- `lifecycle.owner` identifies the team that starts, stops, diagnoses, and recovers the VM.
- `readiness.marker` identifies the durable readiness evidence or command result.
- `readiness.state` is `ready` only when the guest can accept the platform smoke test.
- `readiness.astra_identifier` is the model or client identifier verified by the installed guest account surface.
- `components.cua_repl` identifies the maintained CUA REPL component available in the guest.
- `components.node_repl` identifies the maintained Node REPL component available in the guest.
- `components.client_adapter` identifies an executable guest-side client adapter.
- `credential_status` is `available`, `pending`, or `captain-assistance-required` and never contains a credential value.

A minimal manifest looks like this, with example identities rather than real credentials.

```json
{
  "schema": 1,
  "vm": {"id": "astra-lalo-dev-01", "guest_user": "astra"},
  "reachability": {
    "endpoint": "astra-guest.private",
    "transport": "authenticated-ssh",
    "auth_method": "operator-managed-key",
    "authenticated": true,
    "public": false
  },
  "desktop": {
    "display": ":1",
    "viewer": "authenticated-vnc",
    "browser_profile": "/home/astra/.config/chromium-astra"
  },
  "lifecycle": {"owner": "infra-ops"},
  "readiness": {
    "marker": "/run/astra/ready",
    "state": "ready",
    "astra_identifier": "gpt-6-astra"
  },
  "components": {
    "cua_repl": "/opt/astra/cua_repl",
    "node_repl": "/opt/astra/node_repl",
    "client_adapter": "/opt/astra/fm-codex-client"
  },
  "credential_status": "available"
}
```

Validate the manifest with the platform helper.

```sh
bin/fm-astra-guest.sh check --manifest /guest/path/readiness.json
```

The command prints only non-secret identity and readiness fields.

If readiness is incomplete, the command reports the exact missing interface fields and exits without starting a client.

## Exit codes

Every subcommand reports one of these codes, so a supervising work item can tell a readiness gap apart from an operator mistake and from a guest adapter failure.

| Code | Meaning |
| --- | --- |
| 0 | The command succeeded. |
| 2 | Local operator or state error, such as bad arguments, an unreadable request file, an unusable `--state-dir`, or a refused overwrite. |
| 3 | The readiness manifest is missing or incomplete; report this as `paused: awaiting infra guest readiness` with the named missing fields. |
| 5 | The guest client adapter failed, timed out, was refused because the desktop is paused, or returned an unusable response. |

## Guest preparation

Run preparation as the guest non-root user inside the isolated guest project.

```sh
bin/fm-astra-guest.sh prepare \
  --manifest /guest/path/readiness.json \
  --project /home/astra/fixture-project \
  --state-dir /home/astra/.local/state/firstmate/astra
```

Preparation writes only `.codex/astra-guest.toml` and the state directory under the supplied guest project or state path.

It never overwrites the existing `.codex/config.toml` unless an operator explicitly names the generated sidecar with `--replace-generated`.

`--replace-generated` only regenerates a file this command previously generated, identified by its `# Generated by fm-astra-guest` header; any other existing file is refused with exit 2 so a real Codex config can never be replaced by the sidecar.

The sidecar records the guest display, dedicated browser profile, maintained `cua_repl/node_repl` components, verified Astra identifier, and handoff rules.

The adapter is the maintained guest-side component that invokes Codex CLI/Astra and returns the protocol response.

The platform helper deliberately does not guess a model identifier, copy host authentication, or turn the sidecar into a new Pi or Desktop-app bridge.

OpenAI's current computer-use guidance recommends code execution for Astra and says the application must preserve the browser or desktop session between calls, return current screenshots after bounded action groups, keep image resolution aligned with action coordinates, and distinguish conversation state from execution-environment state.

See [OpenAI computer use](https://platform.openai.com/docs/guides/tools-computer-use) and the [OpenAI CUA sample app](https://github.com/openai/openai-cua-sample-app).

## Serialization and human takeover

Every client call is a JSON request sent to the executable guest adapter and is protected by one exclusive input lock.

The lock covers the complete client call, so GUI, CDP, and human input cannot interleave through this integration.

The dedicated browser profile must be the same profile used for visual and DOM/CDP actions where those tools support a shared session.

Pause the agent before a human takes control.

```sh
bin/fm-astra-guest.sh pause \
  --state-dir /home/astra/.local/state/firstmate/astra \
  --reason "captain takeover"
```

Resume the agent only after the human has left the desktop.

```sh
bin/fm-astra-guest.sh resume --state-dir /home/astra/.local/state/firstmate/astra
```

A paused desktop rejects agent calls until an explicit resume.

A timed-out client process is killed as a process group and the input lock is released in the same cleanup path.

A process crash also releases the kernel lock, while the durable handoff state remains inspectable.

The lock is not a security sandbox for arbitrary code, and a timeout does not make guest code safe.

The guest adapter must enforce the operating-system user boundary, action allow list, cancellation, and confirmation of consequential actions.

## Client request protocol

The adapter reads one JSON object from standard input and writes one JSON object on its final non-empty output line.

The request includes `protocol: 1` and a unique `request_id` added by the platform helper.

The request may contain a prompt or a fixture-specific action list.

The helper sets `FM_ASTRA_REQUEST_ID`, `FM_ASTRA_SESSION_DIR`, `FM_ASTRA_DESKTOP_OWNER=agent`, `FM_ASTRA_BROWSER_PROFILE`, and the guest `DISPLAY` for the adapter.

`FM_ASTRA_REQUEST_ID` carries the same identifier as the request body and the result envelope, so an adapter can correlate its own logs without parsing standard input.

The helper returns a JSON envelope containing the request identifier, observable `duration_ms`, and the adapter response.

Adapter diagnostics stay on standard error and are not copied into the result.

A response key that names a credential is returned as `[redacted]` and listed under the envelope's `redacted` field, so a completed desktop action still reports its result and `duration_ms` while no credential value is ever printed.

Booleans, numbers, and nulls under such a key are returned unchanged, because they cannot carry a credential value and rewriting them would report a wrong result; strings, objects, and arrays are always redacted.

A client command can be exercised directly with a disposable request.

```sh
bin/fm-astra-guest.sh run \
  --manifest /guest/path/readiness.json \
  --state-dir /home/astra/.local/state/firstmate/astra \
  --client /opt/astra/fm-codex-client \
  --timeout 120 \
  --prompt 'Observe the local fixture before taking a short, bounded action group.'
```

Page or document text is untrusted and cannot grant permission or override the operator's instructions.

The adapter must require confirmation before purchases, data transmission, destructive changes, sensitive typing, or other hard-to-reverse actions.

The platform reports actual client execution and observable timings separately from the presence of an installed package.

## Acceptance tests

The offline test covers the protocol and safety contract without a guest.

```sh
tests/fm-astra-guest.test.sh
```

The test uses a temporary fixture outside production repositories and proves form text including Vietnamese, scrolling, shortcut and drag, asynchronous control, stale-click recovery, screenshot coordinate alignment, state across calls, serialized concurrent calls, timed-out input release, and a targeted rich-text edit that preserves unrelated content.

Every `run` envelope reports that call's observable `duration_ms`, and the offline test asserts it; grouped-workflow timing is measured from those per-call durations during the gated live run.

The live portion is intentionally gated and does not run until Infra Ops publishes a ready manifest and a guest adapter command.

```sh
FM_ASTRA_LIVE_MANIFEST=/guest/path/readiness.json \
FM_ASTRA_LIVE_CLIENT=/opt/astra/fm-codex-client \
tests/fm-astra-guest.test.sh
```

The live fixture is disposable and must not be the live JD or another production document.

A missing manifest or any missing readiness field is reported as `paused: awaiting infra guest readiness` by the supervising work item rather than being treated as a successful live proof.

Acceptance is not complete until the guest has authenticated viewing instructions, safe human takeover evidence, passing live calls, bounded resource measurements, and restore evidence or a stated off-host backup limitation from Infra Ops.
