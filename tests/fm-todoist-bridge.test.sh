#!/usr/bin/env bash
# Behavior tests for the Todoist board publication and captain reply bridge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-todoist-publish.sh"
REPLIES="$ROOT/bin/fm-todoist-replies.sh"
TMP_ROOT=$(fm_test_tmproot fm-todoist-bridge)

make_home() {
  local home=$1
  home="$TMP_ROOT/$home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/bin" "$home/fakebin"
  printf '%s\n' "$home"
}

make_fake_curl() {
  local home=$1
  cat >"$home/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
method=GET
previous=
for arg in "$@"; do
  if [ "$previous" = --request ]; then
    method=$arg
  elif [ "$arg" = GET ] || [ "$arg" = POST ]; then
    method=$arg
  fi
  previous=$arg
done
if [ "$method" = GET ]; then
  cat "$FAKE_CURL_RESPONSE"
  exit 0
fi
for arg in "$@"; do
  case "$arg" in
    @*) cat "${arg#@}" >>"$FAKE_CURL_POSTS" ;;
  esac
done
printf '\n' >>"$FAKE_CURL_POSTS"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
SH
  chmod 0755 "$home/fakebin/curl"
}

write_snapshot_fixture() {
  local home=$1
  cat >"$home/bin/fm-fleet-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-09-10T00:00:00Z",
  "backlog": {
    "records": [
      {"structured":true,"id":"done-recent","state":"done","title":"Recent","repo":"alpha","kind":"ship","completion":{"verb":"done","date":"2026-09-05"},"body_lines":[]},
      {"structured":true,"id":"done-old","state":"done","title":"Old","repo":"alpha","kind":"ship","completion":{"verb":"done","date":"2026-09-01"},"body_lines":[]},
      {"structured":true,"id":"captain","state":"queued","title":"Captain route","repo":"alpha","kind":"ship","hold_kind":"captain","hold_reason":"Choose the route","hold_until":null,"body_lines":["options: ship, wait | ask","default: ship","due: 2026-09-12","deadline: 2026-09-30"]},
      {"structured":true,"id":"external","state":"queued","title":"External wait","repo":"alpha","kind":"ship","hold_kind":"external","hold_reason":"Upstream release","hold_until":"2026-09-20","body_lines":[]},
      {"structured":true,"id":"queued","state":"queued","title":"Queued","repo":"alpha","kind":"ship","body_lines":[]},
      {"structured":true,"id":"validation","state":"in_flight","title":"Validation","repo":"alpha","kind":"ship","body_lines":[]},
      {"structured":true,"id":"reviewer","state":"in_flight","title":"Review schedule","repo":"alpha","kind":"scout","body_lines":[]},
      {"structured":true,"id":"ready","state":"in_flight","title":"Ready","repo":"alpha","kind":"ship","pr_url":"https://github.com/example/alpha/pull/1","body_lines":[]},
      {"structured":true,"id":"merged","state":"in_flight","title":"Merged","repo":"alpha","kind":"ship","pr_url":"https://github.com/example/alpha/pull/2","completion":{"verb":"merged","date":"2026-09-10"},"body_lines":[]},
      {"structured":true,"id":"pane-blocked","state":"in_flight","title":"Pane blocked","repo":"alpha","kind":"ship","body_lines":[]},
      {"structured":true,"id":"hidden","state":"queued","title":"Hidden","repo":"alpha","kind":"ship","body_lines":[]}
    ]
  },
  "tasks": [
    {"id":"validation","kind":"ship","harness":"cursor","current_state":{"state":"fixing","source":"run-step","detail":"tests running"},"pr":{"url":null},"hints":{"last_event_text":"working [at=123]: validation started","blocked_event":false}},
    {"id":"reviewer","kind":"scout","harness":"cursor","current_state":{"state":"working","source":"pane","detail":"reviewing"},"pr":{"url":null},"hints":{"last_event_text":"working [at=124]: review started","blocked_event":false}},
    {"id":"ready","kind":"ship","harness":"cursor","current_state":{"state":"done","source":"pane","detail":"checks green"},"pr":{"url":"https://github.com/example/alpha/pull/1"},"hints":{"last_event_text":"done [at=125]: checks green","blocked_event":false}},
    {"id":"merged","kind":"ship","harness":"cursor","current_state":{"state":"done","source":"pane","detail":"merged"},"pr":{"url":"https://github.com/example/alpha/pull/2"},"hints":{"last_event_text":"done [at=126]: merged","blocked_event":false}},
    {"id":"blocked","kind":"ship","harness":"cursor","current_state":{"state":"blocked","source":"run-step","detail":"needs a fix"},"pr":{"url":null},"hints":{"last_event_text":"blocked [at=127]: needs a fix","blocked_event":true}},
    {"id":"pane-blocked","kind":"ship","harness":"cursor","current_state":{"state":"blocked","source":"pane","detail":"waiting on upstream"},"pr":{"url":null},"hints":{"last_event_text":"blocked [at=129]: waiting on upstream","blocked_event":true}},
    {"id":"orphan","kind":"ship","harness":"cursor","current_state":{"state":"working","source":"pane","detail":"coding"},"pr":{"url":null},"hints":{"last_event_text":"working [at=128]: coding","blocked_event":false}}
  ]
}
JSON
EOF
  chmod 0755 "$home/bin/fm-fleet-snapshot.sh"
}

bridge_env() {
  local home=$1
  cat >"$home/config/todoist-bridge.env" <<'EOF'
TODOIST_BRIDGE_PUBLISH_URL=https://bridge.invalid/publish
TODOIST_BRIDGE_REPLIES_URL=https://bridge.invalid/replies
TODOIST_BRIDGE_ACK_URL=https://bridge.invalid/ack
TODOIST_BRIDGE_TOKEN=fixture-secret-token
EOF
}

run_publish() {
  local home=$1 out=$2 status=0
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" FM_TODOIST_SNAPSHOT_BIN="$home/bin/fm-fleet-snapshot.sh" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$PUBLISH" >"$out" 2>&1 || status=$?
  return "$status"
}

test_unconfigured_is_local_success() {
  local home out
  home=$(make_home unconfigured)
  out="$home/out"
  run_publish "$home" "$out" || fail "unconfigured publish should succeed"
  assert_contains "$(cat "$out")" "bridge unconfigured" "unconfigured publish did not explain the no-op"
  [ ! -e "$home/posts" ] || fail "unconfigured publish attempted network access"
  pass "absent bridge configuration stays local and succeeds"
}

test_publish_projects_stages_dates_options_and_hide_list() {
  local home out payload
  home=$(make_home publish)
  bridge_env "$home"
  make_fake_curl "$home"
  write_snapshot_fixture "$home"
  printf '%s\n' hidden >"$home/config/todoist-board-hide"
  out="$home/out"
  run_publish "$home" "$out" || fail "publish fixture failed: $(cat "$out")"
  [ ! -s "$out" ] || fail "successful publish must be silent: $(cat "$out")"
  payload="$home/posts"
  jq -e '
    .schema == "fm-board.v1"
    and ([.items[].key] | index("hidden") | not)
    and ([.items[] | select(.key == "done-recent")][0].stage == "Done this week")
    and ([.items[] | select(.key == "done-old")][0].stage == "archive")
    and ([.items[] | select(.key == "captain")][0]
      | .stage == "Waiting for captain"
      and .question == "Choose the route"
      and .options == ["ship","wait","ask"]
      and .default == "ship"
      and .due == "2026-09-12"
      and .deadline == "2026-09-30"
      and (.labels | index("captain") != null))
    and ([.items[] | select(.key == "external")][0]
      | .stage == "Queued" and .stage_reason == "Waiting (external): Upstream release until 2026-09-20")
    and ([.items[] | select(.key == "validation")][0].stage == "Validation")
    and ([.items[] | select(.key == "reviewer")][0].stage == "UI review")
    and ([.items[] | select(.key == "ready")][0].stage == "Waiting for captain")
    and ([.items[] | select(.key == "merged")][0].stage == "Done this week")
    and ([.items[] | select(.key == "blocked")][0].blocked == true)
    and ([.items[] | select(.key == "pane-blocked")][0]
      | .stage == "In progress" and .blocked == true)
    and ([.items[] | select(.key == "orphan")][0].stage == "In progress")
    and ([.items[] | select(.key == "validation")][0].last_event == "working: validation started")
  ' "$payload" >/dev/null || fail "board projection rules were wrong: $(cat "$payload")"
  pass "publish applies stage rules, dates, options, and hide list"
}

test_publish_never_outputs_token_on_network_failure() {
  local home out status=0
  home=$(make_home token)
  bridge_env "$home"
  make_fake_curl "$home"
  write_snapshot_fixture "$home"
  out="$home/out"
  FAKE_CURL_FAIL=1 run_publish "$home" "$out" || status=$?
  [ "$status" -ne 0 ] || fail "failed publish should be non-zero"
  assert_not_contains "$(cat "$out")" fixture-secret-token "publish output leaked the bearer token"
  pass "publish failure output does not contain the bearer token"
}

test_replies_file_once_and_ack_idempotently() {
  local home out notes body status=0
  home=$(make_home replies)
  bridge_env "$home"
  make_fake_curl "$home"
  cat >"$home/response.json" <<'JSON'
[
  {"id":"r1","card_key":"captain-1","kind":"comment","text":"$(touch SHOULD_NOT_EXIST)\nline two","author":"captain","at":"2026-09-10T00:00:00Z"}
]
JSON
  : >"$home/posts"
  out="$home/out"
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$REPLIES" >"$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "first reply poll failed: $(cat "$out")"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "first poll did not file exactly one captain note"
  body=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' -print -quit)
  assert_contains "$(cat "$body")" "todoist captain-1 comment: \$(touch SHOULD_NOT_EXIST)" "reply prefix or data was changed"
  assert_contains "$(cat "$body")" 'line two' "reply newlines were not retained as data"
  [ ! -e "$home/state/inbox/SHOULD_NOT_EXIST" ] || fail "reply text was evaluated as a command"
  [ "$(grep -c '"id":"r1"' "$home/posts")" = 1 ] || fail "first poll did not acknowledge the event"

  status=0
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$REPLIES" >"$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "second reply poll failed: $(cat "$out")"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "seen event was filed twice"
  [ "$(grep -c '"id":"r1"' "$home/posts")" = 2 ] || fail "seen event was not re-acknowledged"
  pass "replies file unseen text once and acknowledge idempotently"
}

test_replies_tolerate_inbox_wake_failure_without_duplicating() {
  local home out notes status=0
  home=$(make_home replies-wake-fail)
  bridge_env "$home"
  make_fake_curl "$home"
  cat >"$home/fake-inbox.sh" <<'SH'
#!/usr/bin/env bash
set -u
body=$(cat)
inbox="${FM_STATE_OVERRIDE:-${FM_HOME:?}}/inbox"
mkdir -p "$inbox"
id="fixture-note"
printf 'id=%s\nat=2026-09-10T00:00:00Z\nsource=text\n--\n%s\n' "$id" "$body" >"$inbox/$id.note"
printf 'queued %s\n' "$id" >&2
printf 'fm-inbox: note %s is saved at %s/%s.note but firstmate was NOT woken\n' "$id" "$inbox" "$id" >&2
exit 1
SH
  chmod 0755 "$home/fake-inbox.sh"
  cat >"$home/response.json" <<'JSON'
[
  {"id":"wake-fail","card_key":"captain-2","kind":"comment","text":"still one note","author":"captain","at":"2026-09-10T00:00:00Z"}
]
JSON
  : >"$home/posts"
  out="$home/out"
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_TODOIST_INBOX_BIN="$home/fake-inbox.sh" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$REPLIES" >"$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "reply poll should succeed after wake failure: $(cat "$out")"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "wake failure path did not file exactly one captain note"
  grep -F wake-fail "$home/state/todoist-bridge-replies.seen" >/dev/null \
    || fail "wake failure path did not record the event as seen"

  status=0
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_TODOIST_INBOX_BIN="$home/fake-inbox.sh" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$REPLIES" >"$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "second poll after wake failure failed: $(cat "$out")"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "wake failure path duplicated the captain note"
  pass "replies tolerate inbox wake failure without duplicating notes"
}

test_replies_skip_duplicate_after_crash_before_seen() {
  local home out notes status=0
  home=$(make_home replies-crash-seen)
  bridge_env "$home"
  make_fake_curl "$home"
  mkdir -p "$home/state/inbox"
  cat >"$home/state/inbox/crash-note.note" <<'EOF'
id=crash-note
at=2026-09-10T00:00:00Z
source=text
--
todoist-bridge-event-id: crash-before-seen
todoist captain-3 comment: already filed
EOF
  cat >"$home/response.json" <<'JSON'
[
  {"id":"crash-before-seen","card_key":"captain-3","kind":"comment","text":"already filed","author":"captain","at":"2026-09-10T00:00:00Z"}
]
JSON
  : >"$home/posts"
  out="$home/out"
  env FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FAKE_CURL_RESPONSE="$home/response.json" FAKE_CURL_POSTS="$home/posts" \
    PATH="$home/fakebin:$PATH" "$REPLIES" >"$out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "poll after crash-before-seen failed: $(cat "$out")"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$notes" = 1 ] || fail "crash-before-seen path filed a duplicate captain note"
  grep -F crash-before-seen "$home/state/todoist-bridge-replies.seen" >/dev/null \
    || fail "crash-before-seen path did not record the event as seen"
  [ "$(grep -c '"id":"crash-before-seen"' "$home/posts")" = 1 ] \
    || fail "crash-before-seen path did not acknowledge the event"
  pass "replies skip duplicate notes after crash before seen-list update"
}

test_unconfigured_is_local_success
test_publish_projects_stages_dates_options_and_hide_list
test_publish_never_outputs_token_on_network_failure
test_replies_file_once_and_ack_idempotently
test_replies_tolerate_inbox_wake_failure_without_duplicating
test_replies_skip_duplicate_after_crash_before_seen
