# Astra guest commissioning CLI evidence

## Published readiness summary

```text
ready vm=astra-review-fixture guest_user=astra endpoint=fixture.invalid display=:10 viewer=authenticated-fixture-viewer lifecycle_owner=infra-ops credential_status=available astra=gpt-6-astra
```

## Missing readiness is gated with exact interface fields

```text
fm-astra-guest: missing interface fields: schema, vm.id, vm.guest_user, reachability.endpoint, reachability.transport, reachability.auth_method, reachability.authenticated, desktop.display, desktop.viewer, desktop.browser_profile, lifecycle.owner, readiness.marker, readiness.state, readiness.astra_identifier, components.cua_repl, components.node_repl, components.client_adapter, credential_status, reachability.public=false, credential_status(valid state)
exit=3
```

## Additive preparation preserves the existing Codex setting

```text
prepared additive guest config: /home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M1R6HXF2PYCET2TYP7Y20SYY/.astra-e2e-fixture/project/.codex/astra-guest.toml
existing config: model = "existing-host-setting"
sidecar: {'provider': 'codex-cli-astra', 'component': 'cua_repl/node_repl', 'display': ':10', 'browser_profile': '/guest/astra-profile', 'session_persistent': True, 'ownership': 'exclusive', 'timeout_releases_input': True}
```

## Explicit human takeover blocks agent input, then resume restores it

```text
handoff=active generation=0 reason=
handoff=human generation=1
fm-astra-guest: desktop is paused for human takeover; resume explicitly before agent use
blocked exit=5
handoff=active generation=2
{"client": {"ok": true, "value": "Xin chào"}, "duration_ms": 29, "protocol": 1, "request_id": "fbc8e388-490f-4dd1-a7d3-01e01e7e1b6a"}
```

## Two simultaneous desktop calls are serialized

```text
start one
end one
start two
end two
```

## Timeout forwards diagnostics, releases input, and later calls retain state

```text
waiting for guest window
fm-astra-guest: client timed out; desktop input lock released
timeout exit=5
{"client": {"ok": true, "value": "Xin chào thế giới"}, "duration_ms": 26, "protocol": 1, "request_id": "251b4d07-7b13-45e2-878b-b2d6374384f8"}
```

## Disposable rich-text edit preserves unrelated content

```text
{"client": {"document": {"body": ["Keep paragraph", "Edited paragraph"], "footer": "Keep footer", "title": "Keep title"}, "ok": true}, "duration_ms": 25, "protocol": 1, "request_id": "7e02ca35-fca6-43d4-9914-ad047d1aad1b"}
```
