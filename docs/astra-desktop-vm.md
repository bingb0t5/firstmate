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
- `readiness.marker` identifies the current readiness evidence or command result.
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

The command validates manifest structure and prints only non-secret identity and readiness fields.

It does not inspect the published component paths or run an account/desktop probe.
The maintained adapter and readiness publisher below perform those checks inside the guest.

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

Preparation writes one generated sidecar under the supplied guest project, defaulting to `.codex/astra-guest.toml`, and records the supplied state path in that sidecar.

The state directory is created lazily when handoff state is first accessed.

The default preparation path leaves an existing `.codex/config.toml` unchanged.

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

Handoff status remains readable while a client call holds the input lock, while pause and resume wait for exclusive ownership before changing the durable state.

A timed-out client process is killed as a process group and the input lock is released in the same cleanup path.

The helper also kills remaining descendants after a successful client exit, before releasing the input lock.

A process crash also releases the kernel lock, while the durable handoff state remains inspectable.

The lock is not a security sandbox for arbitrary code, and a timeout does not make guest code safe.

The guest adapter must enforce the operating-system user boundary, action allow list, cancellation, and confirmation of consequential actions.

## Client request protocol

The adapter reads one JSON object from standard input and writes one JSON object on its final non-empty output line.

The request includes `protocol: 1` and a unique `request_id` added by the platform helper.

Both directions of the channel are UTF-8 regardless of the ambient locale: the helper writes the request line as UTF-8 and decodes the adapter's output as UTF-8, so an adapter that reads or writes with the locale codeset fails on non-ASCII text under a `C` or `POSIX` service session.

A Python adapter should call `sys.stdin.reconfigure(encoding="utf-8")` and `sys.stdout.reconfigure(encoding="utf-8")` before reading the request.

The request may contain a prompt or a fixture-specific action list.

The helper sets `FM_ASTRA_REQUEST_ID`, `FM_ASTRA_SESSION_DIR`, `FM_ASTRA_DESKTOP_OWNER=agent`, `FM_ASTRA_BROWSER_PROFILE`, and the guest `DISPLAY` for the adapter.

`FM_ASTRA_REQUEST_ID` carries the same identifier as the request body and the result envelope, so an adapter can correlate its own logs without parsing standard input.

The helper returns a JSON envelope containing the request identifier, observable `duration_ms`, and the adapter response.

Adapter diagnostics are captured from standard error and are never copied into the result.

When a call fails, the adapter's captured standard error is written through to the operator's standard error so a failing guest adapter is debuggable.

On a successful call, non-empty diagnostics are suppressed and replaced by a one-line note.

Diagnostics are free text and are not redacted, so an adapter must not print credential values.

Bytes on that stream that are not valid UTF-8 are replaced rather than failing the call, so a native tool writing a locale-encoded warning can never discard a completed action's result.

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

## Maintained Linux guest adapter

[`bin/fm-codex-client.py`](../bin/fm-codex-client.py) installs as `/home/astra/.local/bin/fm-codex-client`.
It targets the commissioned non-root `astra` user, display `:1`, profile `/home/astra/.config/chromium-astra`, and shared state `/home/astra/.local/state/firstmate/astra`.
It invokes Codex CLI 0.153.4's public experimental `app-server --listen stdio://` interface with `gpt-6-astra`, a read-only shell sandbox, and `on-request` approval.
It starts no daemon or private Desktop bridge, does not change Codex configuration files, and keeps descendants in the helper's existing process group.
Version changes fail closed until the protocol is revalidated.
The CLI's `exec` mode cannot serve this adapter because its noninteractive approval policy refuses the CUA tool approval request.

The maintained CUA launcher, Node REPL, Node runtime, and `codex-code-mode-host` companion must already be installed at the paths returned by the adapter's `components()` function.
The adapter does not install or replace those upstream components.
It does not launch or close Chrome or change its profile.
The guest desktop and browser session persist across calls; the Codex thread and JavaScript variables do not.
Native Linux coordinate control is supported; this adapter does not expose DOM/CDP, accessibility trees, crop operations, arbitrary JavaScript, or free-form prompt execution.
It does not read credential stores or provide a credential handoff.
Current supported scope is native desktop control, not completion of the broader commissioning acceptance suite.

Use a protocol-1 request file with `operation` equal to `observe`, `smoke`, or `actions`.
The helper supplies `request_id`; direct calls without its environment and process-group context are refused.
`observe` obtains a screenshot and requires a current readiness marker.
`smoke` performs the same read-only observation without requiring that marker, allowing the publisher to commission a pending guest without fabricating readiness.
An optional `model` must be exactly `gpt-6-astra`.
Nonempty `prompt` requests are refused with `unsupported_prompt_use_actions`; the adapter does not silently interpret natural-language requests as authorization.

`actions` accepts at most twelve explicit native actions per request.
Every nonempty action list requires `confirm_actions: true`, including clicks, keys, typing, scrolling, movement, drag, and waits.
The caller must obtain confirmation of the exact action group before setting that field, especially for submission, purchases, deletion, transmission, or other consequential actions.
Do not put credentials or sensitive text in action requests.
The adapter returns `confirmation_required` before starting Codex when confirmation is absent; it does not retain a pending approval or create another handoff lock.

| Action `type` | Fields |
| --- | --- |
| `click` | Integer `x`, `y`; optional `mouse_button` (`left`, `right`, `middle`) and `click_count` (1 or 2). |
| `move` | Integer `x`, `y`. |
| `drag` | `path`: 2-32 objects with integer `x`, `y`. |
| `scroll` | `direction` (`up`, `down`, `left`, `right`), integer `pixels` (1-4096), optional paired `x`, `y`. |
| `press_key` | `key`: a keysym-style chord, for example `Control_L+a`. |
| `type_text` | `text`: 1-8192 Unicode characters, including Vietnamese. |
| `wait` | Integer `milliseconds` (1-1000). |

Coordinates are native desktop screenshot coordinates; the adapter does not rescale or guess them.
Observe first, use a short coherent action group, and inspect the guest display after uncertain changes before authorizing another group.
A group ends with one screenshot returned as image content to Astra.
The adapter approves only the fixed CUA initialization call followed by the exact generated action/screenshot call, and refuses additional or altered calls; it never retries a partially executed group.
An error may follow partial input and does not imply rollback.
The read-only Codex shell sandbox does not constrain confirmed desktop input, and neither the schema nor timeout is an operating-system security sandbox.
Keep production data and unrelated credentials out of the isolated guest.

The single JSON response contains fixed non-secret metadata: `ok`, exact `model`, `actions_completed`, `screenshot_observed`, display/profile identity, and the unsupported DOM/CDP flag.
It does not echo typed text, model prose, raw tool results, images, or upstream diagnostics.
Images are available to Astra within the guest turn; operators observe the desktop through Infra's existing authenticated viewer.
Failures return a fixed error code in JSON and a constant diagnostic on stderr, exiting 5.
Missing auth, model mismatch, unknown approval forms, tool failures, malformed UTF-8/JSON, and timeouts all refuse success.

## Installation and readiness publication

[`bin/fm-astra-install.sh`](../bin/fm-astra-install.sh) owns the exact installation commands and paths; read its header or `--help` before applying it inside the VM as `astra` or guest root.
Transfer that script with its four named sibling artifacts from the same reviewed revision.
It installs the adapter, readiness publisher, and helper as `astra:astra`, executable mode `0755`, and restricts the guest artifact/state directories and manifest to their owner.
When run as root it also creates `/run/astra` as `astra:astra`, mode `0700`; otherwise it prints Infra's exact prerequisite command if that directory is absent.
The install joins the existing helper input lock and removes stale readiness.
It neither signs in nor publishes readiness.
The runtime directory is volatile; Infra must recreate it after reboot before refreshing readiness.

[`bin/fm-astra-ready.py`](../bin/fm-astra-ready.py) owns the guest `refresh` and `remove` commands, installed as `/home/astra/.local/bin/fm-astra-ready`.
Run it as `astra`, using the commands in its header or usage output.
It uses `/home/astra/.local/share/codex/readiness.json` and the helper's existing lock and process-group cleanup.
Refresh first removes `/run/astra/ready`, records pending state, checks every published component path, executable adapter ownership/mode, authenticated guest account status, and matching guest identities.
It then executes a fresh authorized read-only `gpt-6-astra` screenshot smoke and publishes a mode-`0600` marker only after that turn succeeds.
The marker records the exact model, timestamp, adapter SHA-256, smoke request ID, and native-only scope.
An existing marker, bundled model catalog, package installation, or caller-supplied smoke receipt cannot satisfy this gate.
Normal adapter calls check the marker and its adapter digest, and recheck account status before each turn.
Refresh failures leave readiness pending with a named condition; `remove` withdraws the marker and records `operator_removed`.
The manifest and marker contain only non-secret state; the marker is the final publication authority if an interrupted write leaves their states different.

## Acceptance tests

The offline test covers the protocol and safety contract without a guest.

```sh
tests/fm-astra-guest.test.sh
tests/fm-codex-client.test.sh
```

The test uses a temporary fixture outside production repositories and proves form text including Vietnamese, scrolling, shortcut and drag, asynchronous control, stale-click recovery, screenshot coordinate alignment, state across calls, serialized concurrent calls, timed-out input release, and a targeted rich-text edit that preserves unrelated content.

Every `run` envelope reports that call's observable `duration_ms`, and the offline test asserts it.

During live acceptance, record grouped-workflow timing from the observed per-call durations.

The live smoke is intentionally gated and does not run until Infra Ops publishes a ready manifest and a guest adapter command.

```sh
FM_ASTRA_LIVE_MANIFEST=/guest/path/readiness.json \
FM_ASTRA_LIVE_CLIENT=/opt/astra/fm-codex-client \
tests/fm-astra-guest.test.sh
```

The live fixture is disposable and must not be the live JD or another production document.

The env-gated fixture test validates the published manifest, Vietnamese form text, and a screenshot response using a fixture-specific client protocol.
It is not the maintained native adapter's request schema and must not be cited as live proof of that adapter.
Use the readiness publisher for its exact-model native screenshot smoke, then separately commission the remaining native workflows with explicit confirmed action lists on disposable fixtures.

Complete live acceptance still requires the remaining operations named above through the real MCP/client integration and guest adapter.

A missing manifest or any missing readiness field is reported as `paused: awaiting infra guest readiness` by the supervising work item rather than being treated as a successful live proof.

Acceptance is not complete until the guest has authenticated viewing instructions, safe human takeover evidence, passing live calls, bounded resource measurements, and restore evidence or a stated off-host backup limitation from Infra Ops.
