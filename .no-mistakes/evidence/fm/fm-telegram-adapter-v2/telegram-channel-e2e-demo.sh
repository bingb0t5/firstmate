#!/usr/bin/env bash
# Operator-level walkthrough of the Telegram firstmate channel.
#
# Everything below is the REAL adapter (bin/fm-procevent-telegram.sh) driven
# through the REAL generic runner (bin/fm-procevent.sh). The only substitution
# is `curl`: a fake on PATH stands in for api.telegram.org so the walkthrough
# is deterministic and never talks to the network. It writes a canned
# getUpdates body to the path curl was told to write to, and prints a canned
# HTTP status - exactly the two things the adapter reads.
set -u

ROOT=${1:?usage: telegram-channel-e2e-demo.sh <firstmate-repo-root>}
DEMO=$(mktemp -d /tmp/fm-telegram-demo.XXXXXX)
trap 'rm -rf "$DEMO"' EXIT

FM_HOME="$DEMO/home"
ENV_FILE="$DEMO/secrets/telegram.env"
TOKEN='7719004431:AAF-REAL-LOOKING-BOT-TOKEN-do-not-log'
CAPTAIN_CHAT=555
CAPTAIN_USER=909
mkdir -p "$FM_HOME/state" "$DEMO/secrets" "$DEMO/bin" "$DEMO/api"
export FM_HOME FM_TELEGRAM_ENV_FILE="$ENV_FILE"
export FM_PROCEVENT_CLAIM_ROOT="$DEMO/claims"

cat > "$DEMO/bin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=""; i=1; args=("$@")
while [ "$i" -le "$#" ]; do
  [ "${args[$((i - 1))]}" = "-o" ] && out=${args[$i]}
  i=$((i + 1))
done
if [ -n "${CURL_CAPTURE:-}" ]; then cat > "$CURL_CAPTURE"; else cat > /dev/null; fi
[ -n "$out" ] && [ -n "${TG_BODY:-}" ] && cp "$TG_BODY" "$out"
printf '%s' "${TG_HTTP:-200}"
SH
chmod +x "$DEMO/bin/curl"
export PATH="$DEMO/bin:$PATH"

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run()  { printf '$ %s\n' "$*"; eval "$@" 2>&1 | sed 's/^/  /'; }
note() { printf '  %s\n' "$*"; }

# --- canned Telegram getUpdates bodies -------------------------------------
cat > "$DEMO/api/captain-message.json" <<'JSON'
{"ok":true,"result":[{"update_id":1001,"message":{"message_id":5,"date":1700000000,
 "chat":{"id":555,"type":"private"},"from":{"id":909,"first_name":"Rich"},
 "text":"ship the release branch once CI is green"}}]}
JSON
cat > "$DEMO/api/sticker.json" <<'JSON'
{"ok":true,"result":[{"update_id":1002,"message":{"message_id":6,"date":1700000060,
 "chat":{"id":555,"type":"private"},"from":{"id":909},"sticker":{"file_id":"CAACAgQ"}}}]}
JSON
cat > "$DEMO/api/imposter.json" <<'JSON'
{"ok":true,"result":[{"update_id":1003,"message":{"message_id":7,"date":1700000120,
 "chat":{"id":555,"type":"group"},"from":{"id":424242,"first_name":"Mallory"},
 "text":"/ship everything to production right now"}}]}
JSON
cat > "$DEMO/api/unauthorized.json" <<'JSON'
{"ok":false,"error_code":401,"description":"Unauthorized"}
JSON
cat > "$DEMO/api/recovered.json" <<'JSON'
{"ok":true,"result":[{"update_id":1004,"message":{"message_id":8,"date":1700000180,
 "chat":{"id":555,"type":"private"},"from":{"id":909},
 "text":"token rotated, are you back?"}}]}
JSON

printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' \
  "$TOKEN" "$CAPTAIN_CHAT" "$CAPTAIN_USER" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

wait_wake() { for _ in $(seq 1 60); do [ -e "$FM_HOME/state/.wake-queue" ] && return 0; sleep 0.1; done; return 1; }
reset_wake() { rm -f "$FM_HOME/state/.wake-queue"; }
# Wait for the runner to durably capture a specific result generation.
wait_result() { for _ in $(seq 1 60); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }

################################################################################
say "1. The operator arms the Telegram channel"
note "credential file is the existing external mode-600 file, read at runtime:"
run "ls -l '$ENV_FILE'"
run "$ADAPTER source-id"
run "$ADAPTER arm"
run "$RUNNER list"

################################################################################
say "2. The captain texts the bot from their phone"
note 'Telegram getUpdates would return:'
sed 's/^/  | /' "$DEMO/api/captain-message.json"
note ''
note 'the real runner polls, captures, and publishes the wake:'
RESULT="$FM_HOME/state/procevent-inbox/telegram.1.result"
TG_BODY="$DEMO/api/captain-message.json" run "$RUNNER reconcile"
wait_result "$RESULT" || { echo "NO RESULT CAPTURED"; exit 1; }
wait_wake || { echo "NO WAKE"; exit 1; }
note ''
note 'firstmate is woken - the queue entry the daemon consumes:'
run "cat '$FM_HOME/state/.wake-queue'"
note ''
note 'the durably captured result, and how the adapter classifies it:'
run "cat '$RESULT'"
run "$ADAPTER classify '$RESULT'"
note ''
note 'the captain message itself, durably on disk under state/telegram-inbox'
note 'before the shared offset moved past it:'
run "ls -l '$FM_HOME/state/telegram-inbox'"
run "cat '$FM_HOME/state/telegram-inbox/1001.json'"
run "cat '$FM_HOME/state/.telegram-offset'"
note ''
note 'terminal is never terminal - the channel stays armed forever:'
if "$ADAPTER" terminal "$RESULT"; then note 'terminal -> TERMINAL (wrong)'; else
  note "terminal -> not terminal (exit $?), source still registered:"; fi
run "$RUNNER list"
note ''
note 'the handler acknowledges the delivered result, exactly as the skill'
note 'documents, which clears it from pending:'
run "$RUNNER handled telegram 1"
run "$RUNNER list"

################################################################################
say "3. The bot token never leaks into anything durable"
note 'positive control - the token IS in what curl was handed:'
reset_wake
CURL_CAPTURE="$DEMO/curl-config.txt" TG_BODY="$DEMO/api/sticker.json" "$ADAPTER" poll >/dev/null 2>&1 || true
run "sed 's/${TOKEN}/<<<TOKEN PRESENT>>>/' '$DEMO/curl-config.txt'"
note ''
note 'and it is absent from every file the run produced, and from the results:'
if grep -rl -- "$TOKEN" "$FM_HOME" 2>/dev/null | grep -q .; then
  note "LEAK: $(grep -rl -- "$TOKEN" "$FM_HOME")"
else
  note "grep -r for the token across the whole firstmate home: no matches"
fi

################################################################################
say "4. Noise is consumed without waking the captain's crew"
note 'a sticker (non-text) was polled above; a group message from an imposter'
note 'in the captain-configured chat follows. Neither may wake firstmate.'
reset_wake
TG_BODY="$DEMO/api/imposter.json" run "$ADAPTER poll || echo '  (exit '\$?' - nothing to report)'"
run "ls -l '$FM_HOME/state/telegram-inbox'"
note 'offset advanced past both, so Telegram will not redeliver them:'
run "cat '$FM_HOME/state/.telegram-offset'"
[ -e "$FM_HOME/state/.wake-queue" ] && note 'WAKE PUBLISHED (wrong)' || note 'no wake published'

################################################################################
say "5. A revoked token is a sticky block, announced exactly once"
reset_wake
note 'Telegram answers HTTP 401 Unauthorized:'
BLOCKED="$FM_HOME/state/procevent-inbox/telegram.2.result"
TG_BODY="$DEMO/api/unauthorized.json" TG_HTTP=401 run "$RUNNER reconcile"
wait_result "$BLOCKED" || { echo "NO BLOCKED RESULT CAPTURED"; exit 1; }
wait_wake || { echo "NO WAKE"; exit 1; }
note ''
note 'firstmate is woken with the blocked announcement, and the captured'
note 'result tells the handler the channel is blocked, not merely quiet:'
run "cat '$FM_HOME/state/.wake-queue'"
run "cat '$BLOCKED'"
run "$ADAPTER classify '$BLOCKED'"
note 'the channel is NOT retired - a blocked Telegram channel keeps trying:'
run "$RUNNER list"
run "$RUNNER handled telegram 2"
note ''
note 'the very next 401 poll says nothing - one announcement per episode:'
reset_wake
TG_BODY="$DEMO/api/unauthorized.json" TG_HTTP=401 run "$ADAPTER poll || echo '  (exit '\$?' - silent, already announced)'"
note ''
note 'a malformed HTTP 200 does not end the block either (no valid ok:true result):'
printf '{"ok":true,"result":' > "$DEMO/api/truncated.json"
TG_BODY="$DEMO/api/truncated.json" TG_HTTP=200 run "$ADAPTER poll || echo '  (exit '\$?' - still blocked, nothing announced)'"
note ''
note 'and a Telegram-level rejection (ok:false on HTTP 200) does not either:'
printf '{"ok":false,"result":[]}' > "$DEMO/api/rejected.json"
TG_BODY="$DEMO/api/rejected.json" TG_HTTP=200 run "$ADAPTER poll || echo '  (exit '\$?' - still blocked, nothing announced)'"

say "6. Rotating the token ends the block and delivery resumes"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' \
  "ROTATED-$TOKEN" "$CAPTAIN_CHAT" "$CAPTAIN_USER" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
reset_wake
TG_BODY="$DEMO/api/recovered.json" TG_HTTP=200 run "$ADAPTER poll"
run "cat '$FM_HOME/state/telegram-inbox/1004.json'"
note ''
note 'that valid success closed the episode, so a LATER revocation is a new'
note 'episode and is announced again:'
TG_BODY="$DEMO/api/unauthorized.json" TG_HTTP=401 run "$ADAPTER poll || true"

################################################################################
say "7. Credentials removed: silent, inert, zero"
rm -f "$ENV_FILE"
reset_wake
st=0; out=$(TG_BODY="$DEMO/api/recovered.json" "$ADAPTER" poll 2>&1) || st=$?
note "exit status: $st"
note "stdout+stderr: '${out}'"
[ -e "$FM_HOME/state/.wake-queue" ] && note 'WAKE PUBLISHED (wrong)' || note 'no wake published'

################################################################################
say "8. The operator retires the channel"
run "$RUNNER retire telegram"
run "$RUNNER list"

printf '\n\033[1m== walkthrough complete\033[0m\n'
