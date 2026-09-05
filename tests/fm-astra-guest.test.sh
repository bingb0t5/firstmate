#!/usr/bin/env bash
# The guest integration is portable when the client adapter is a disposable
# fixture and live-gated when Infra Ops publishes a ready guest manifest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-astra-guest.sh"

manifest_json() {
  local path=$1 state=$2
  cat > "$path" <<EOF
{
  "schema": 1,
  "vm": {"id": "astra-fixture", "guest_user": "astra"},
  "reachability": {
    "endpoint": "fixture.invalid",
    "transport": "authenticated-test-transport",
    "auth_method": "operator-managed-test-auth",
    "authenticated": true,
    "public": false
  },
  "desktop": {
    "display": ":1",
    "viewer": "authenticated-fixture-viewer",
    "browser_profile": "$state/browser-profile"
  },
  "lifecycle": {"owner": "infra-ops"},
  "readiness": {
    "marker": "$state/ready",
    "state": "ready",
    "astra_identifier": "gpt-6-astra"
  },
  "components": {
    "cua_repl": "/guest/cua_repl",
    "node_repl": "/guest/node_repl",
    "client_adapter": "/guest/client-adapter"
  },
  "credential_status": "available"
}
EOF
}

write_fixture_client() {
  local path=$1
  cat > "$path" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time
from pathlib import Path

root = Path(os.environ["FM_ASTRA_SESSION_DIR"])
state_path = root / "fixture-state.json"
log_path = root / "critical.log"
state = json.loads(state_path.read_text()) if state_path.exists() else {
    "form": "", "scroll": 0, "stale": True,
    "document": {"title": "Keep title", "body": ["Keep this paragraph", "Edit this paragraph"], "footer": "Keep footer"},
}
request = json.loads(sys.stdin.readline())
action = request.get("action")

if action == "form":
    state["form"] += request["text"]
    result = {"ok": True, "value": state["form"]}
elif action == "scroll":
    state["scroll"] += int(request["amount"])
    result = {"ok": True, "scroll": state["scroll"]}
elif action == "shortcut":
    result = {"ok": True, "shortcut": request["keys"]}
elif action == "drag":
    result = {"ok": True, "from": request["from"], "to": request["to"]}
elif action == "async":
    time.sleep(float(request.get("seconds", 0.05)))
    result = {"ok": True, "completed": True}
elif action == "click":
    if state["stale"]:
        result = {"ok": False, "error": "stale-click", "screenshot": {"width": 1200, "height": 800}}
    else:
        result = {"ok": True, "clicked": request["point"]}
elif action == "observe":
    state["stale"] = False
    result = {"ok": True, "screenshot": {"width": 1200, "height": 800}}
elif action == "screenshot":
    result = {"ok": True, "screenshot": {"width": 1200, "height": 800, "scale": 1}}
elif action == "critical":
    with log_path.open("a", encoding="utf-8") as log:
        log.write("start " + request["name"] + "\n")
        log.flush()
        time.sleep(float(request.get("seconds", 0.1)))
        log.write("end " + request["name"] + "\n")
    result = {"ok": True, "critical": request["name"]}
elif action == "slow":
    time.sleep(float(request.get("seconds", 2)))
    result = {"ok": True, "slow": True}
elif action == "rich_edit":
    state["document"]["body"][1] = request["replacement"]
    result = {"ok": True, "document": state["document"]}
else:
    result = {"ok": False, "error": "unknown action"}

state_path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
print(json.dumps(result, ensure_ascii=False))
PY
  chmod +x "$path"
}

write_request() {
  local path=$1 action=$2 extra=${3:-}
  printf '{"action":"%s"%s}\n' "$action" "$extra" > "$path"
}

run_fixture() {
  local manifest=$1 state=$2 client=$3 request=$4 timeout=${5:-5}
  "$RUNNER" run --manifest "$manifest" --state-dir "$state" --client "$client" \
    --timeout "$timeout" --request "$request"
}

test_readiness_contract() {
  local root manifest output status
  root=$(fm_test_tmproot astra-readiness)
  manifest="$root/readiness.json"
  manifest_json "$manifest" "$root"
  output=$("$RUNNER" check --manifest "$manifest")
  assert_contains "$output" "ready vm=astra-fixture guest_user=astra" "readiness summary identifies the isolated guest"
  assert_not_contains "$output" "operator-managed-test-auth" "readiness summary does not expose authentication material"

  printf '{}\n' > "$root/missing.json"
  status=0
  output=$("$RUNNER" check --manifest "$root/missing.json" 2>&1) || status=$?
  expect_code 3 "$status" "incomplete readiness manifest is gated"
  assert_contains "$output" "vm.id, vm.guest_user" "missing fields are named for Infra Ops"

  python3 - "$root/unsafe.json" <<'PY'
import json
import sys
json.dump({"schema": 1, "api_key": "must-never-be-published"}, open(sys.argv[1], "w"))
PY
  status=0
  output=$("$RUNNER" check --manifest "$root/unsafe.json" 2>&1) || status=$?
  expect_code 3 "$status" "credential-bearing readiness manifest is rejected"
  assert_not_contains "$output" "must-never-be-published" "credential value is never echoed"
  pass "readiness contract validates required fields and suppresses credential values"
}

test_additive_prepare() {
  local root manifest project existing output
  root=$(fm_test_tmproot astra-prepare)
  manifest="$root/readiness.json"
  project="$root/project"
  mkdir -p "$project/.codex"
  manifest_json "$manifest" "$root"
  existing='model = "existing"'
  printf '%s\n' "$existing" > "$project/.codex/config.toml"
  output=$("$RUNNER" prepare --manifest "$manifest" --project "$project" --state-dir "$root/state")
  assert_contains "$output" "prepared additive guest config" "preparation writes the guest sidecar"
  [ "$(cat "$project/.codex/config.toml")" = "$existing" ] || fail "preparation changed the existing Codex config"
  assert_grep 'component = "cua_repl/node_repl"' "$project/.codex/astra-guest.toml" "sidecar selects maintained CUA components"
  assert_grep 'session_persistent = true' "$project/.codex/astra-guest.toml" "sidecar preserves a persistent guest session"
  pass "preparation is additive and leaves the existing Codex config intact"
}

test_serialized_fixture_calls() {
  local root manifest state client request output status
  root=$(fm_test_tmproot astra-fixture)
  manifest="$root/readiness.json"
  state="$root/state"
  client="$root/client.py"
  request="$root/request.json"
  manifest_json "$manifest" "$root"
  write_fixture_client "$client"

  write_request "$request" form ',"text":"Xin chào"'
  output=$(run_fixture "$manifest" "$state" "$client" "$request")
  assert_contains "$output" 'Xin chào' "form accepts Vietnamese text"
  write_request "$request" form ',"text":" world"'
  output=$(run_fixture "$manifest" "$state" "$client" "$request")
  assert_contains "$output" 'Xin chào world' "client state persists across calls"

  write_request "$request" scroll ',"amount":240'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"scroll": 240' "scroll is delivered"
  write_request "$request" shortcut ',"keys":"CTRL+SHIFT+S"'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" 'CTRL+SHIFT+S' "keyboard shortcut is delivered"
  write_request "$request" drag ',"from":[20,30],"to":[400,500]'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"to": [400, 500]' "drag coordinates are delivered"
  write_request "$request" async ',"seconds":0.01'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"completed": true' "asynchronous control completes"

  write_request "$request" click ',"point":[200,100]'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" 'stale-click' "stale click is surfaced"
  write_request "$request" observe
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"width": 1200' "observation returns aligned screenshot dimensions"
  write_request "$request" click ',"point":[200,100]'
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"clicked": [200, 100]' "stale click recovers after observation"
  write_request "$request" screenshot
  assert_contains "$(run_fixture "$manifest" "$state" "$client" "$request")" '"scale": 1' "screenshot coordinate scale is explicit"

  write_request "$request" rich_edit ',"replacement":"Edited paragraph"'
  output=$(run_fixture "$manifest" "$state" "$client" "$request")
  assert_contains "$output" 'Keep title' "rich-text edit preserves unrelated heading"
  assert_contains "$output" 'Keep footer' "rich-text edit preserves unrelated footer"
  assert_contains "$output" 'Edited paragraph' "rich-text edit changes only the target"

  local request_one="$root/request-one.json" request_two="$root/request-two.json"
  write_request "$request_one" critical ',"name":"one","seconds":0.15'
  run_fixture "$manifest" "$state" "$client" "$request_one" >/dev/null &
  local first=$!
  write_request "$request_two" critical ',"name":"two","seconds":0.15'
  run_fixture "$manifest" "$state" "$client" "$request_two" >/dev/null &
  local second=$!
  wait "$first"
  wait "$second"
  [ "$(grep -c '^start ' "$state/critical.log")" = 2 ] || fail "both concurrent calls did not run"
  local line_one line_two line_three line_four
  line_one=$(sed -n '1p' "$state/critical.log")
  line_two=$(sed -n '2p' "$state/critical.log")
  line_three=$(sed -n '3p' "$state/critical.log")
  line_four=$(sed -n '4p' "$state/critical.log")
  case "$line_one:$line_two:$line_three:$line_four" in
    "start one:end one:start two:end two"|"start two:end two:start one:end one") : ;;
    *) fail "desktop input calls interleaved" ;;
  esac

  "$RUNNER" pause --state-dir "$state" --reason "fixture human takeover" >/dev/null
  status=0
  run_fixture "$manifest" "$state" "$client" "$request" >/dev/null 2>&1 || status=$?
  expect_code 5 "$status" "paused desktop rejects agent input"
  "$RUNNER" resume --state-dir "$state" >/dev/null

  write_request "$request" slow ',"seconds":2'
  status=0
  output=$(run_fixture "$manifest" "$state" "$client" "$request" 0.1 2>&1) || status=$?
  expect_code 5 "$status" "timed-out call returns client failure"
  assert_contains "$output" "input lock released" "timeout reports input release"
  write_request "$request" form ',"text":" after-timeout"'
  output=$(run_fixture "$manifest" "$state" "$client" "$request")
  assert_contains "$output" 'after-timeout' "client continues after timeout cleanup"
  pass "fixture proves actions, recovery, state, serialization, timeout cleanup, and rich-text preservation"
}

test_live_acceptance_gate() {
  if [ -z "${FM_ASTRA_LIVE_MANIFEST:-}" ] || [ -z "${FM_ASTRA_LIVE_CLIENT:-}" ]; then
    printf 'skip: infra guest readiness not confirmed (set FM_ASTRA_LIVE_MANIFEST and FM_ASTRA_LIVE_CLIENT)\n'
    return 0
  fi
  local root state request output
  root=$(fm_test_tmproot astra-live)
  state="$root/state"
  request="$root/request.json"
  "$RUNNER" check --manifest "$FM_ASTRA_LIVE_MANIFEST" >/dev/null || fail "published guest readiness did not validate"
  write_request "$request" form ',"text":"Xin chào từ guest"'
  output=$(run_fixture "$FM_ASTRA_LIVE_MANIFEST" "$state" "$FM_ASTRA_LIVE_CLIENT" "$request" 120)
  assert_contains "$output" 'Xin chào từ guest' "live guest client accepts Vietnamese fixture text"
  write_request "$request" screenshot
  assert_contains "$(run_fixture "$FM_ASTRA_LIVE_MANIFEST" "$state" "$FM_ASTRA_LIVE_CLIENT" "$request" 120)" '"width"' "live guest returns a screenshot"
  pass "live guest smoke passed against the published readiness contract"
}

test_readiness_contract
test_additive_prepare
test_serialized_fixture_calls
test_live_acceptance_gate
