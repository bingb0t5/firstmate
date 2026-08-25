#!/usr/bin/env bash
# Operator-shaped walkthrough of the adopted Telegram process-event channel.
# Stands in for a real phone + real Bot API by stubbing curl's getUpdates
# response; everything downstream (adapter, generic runner, wake queue) is the
# real shipped code from this worktree.
set -uo pipefail

ROOT=${ROOT:?set ROOT to the worktree}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=""; i=1; argc=$#; args=("$@")
while [ "$i" -le "$argc" ]; do
  [ "${args[$((i - 1))]}" = "-o" ] && out=${args[$i]}
  i=$((i + 1))
done
cat > /dev/null
[ -n "$out" ] && [ -n "${CURL_STUB_BODY:-}" ] && cp "$CURL_STUB_BODY" "$out"
printf '%s' "${CURL_STUB_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

say() { printf '\n\033[1m$ %s\033[0m\n' "$*"; }
run() { say "$*"; eval "$*"; }

HOME_DIR="$TMP/fm-home"; mkdir -p "$HOME_DIR/state"
ENVF="$TMP/telegram.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' \
  '77777:AAH-demo-bot-token' '555' '909' > "$ENVF"
chmod 600 "$ENVF"
export FM_HOME="$HOME_DIR" FM_TELEGRAM_ENV_FILE="$ENVF"

printf '===============================================================\n'
printf ' 1. Operator configures the bot credential and arms the channel\n'
printf '===============================================================\n'
run "ls -l '$ENVF' | sed 's| .*telegram.env| ~/.config/beanz/telegram.env|'"
run "sed 's|TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=<redacted>|' '$ENVF'"
run "'$ROOT/bin/fm-procevent-telegram.sh' source-id"
run "'$ROOT/bin/fm-procevent-telegram.sh' arm"
run "ls '$HOME_DIR/state/procevent/'"

printf '\n===============================================================\n'
printf ' 2. The captain sends a Telegram message from their phone\n'
printf '===============================================================\n'
cat > "$TMP/captain-msg.json" <<'JSON'
{"ok":true,"result":[{"update_id":1001,"message":{"message_id":5,"date":1700000000,"chat":{"id":555},"from":{"id":909},"text":"ahoy - status on the telegram fork PR?"}}]}
JSON
say "(Telegram getUpdates now returns the captain's message)"
python3 -m json.tool "$TMP/captain-msg.json"
run "CURL_STUB_BODY='$TMP/captain-msg.json' '$ROOT/bin/fm-procevent.sh' reconcile"
for _ in $(seq 1 60); do [ -e "$HOME_DIR/state/.wake-queue" ] && break; sleep 0.1; done

printf '\n--- firstmate is woken (state/.wake-queue) ---\n'
cat "$HOME_DIR/state/.wake-queue"
printf '\n--- the message firstmate can now read (state/telegram-inbox/) ---\n'
ls "$HOME_DIR/state/telegram-inbox/"
python3 -m json.tool "$HOME_DIR/state/telegram-inbox/1001.json"
printf '\n--- the captured result and how a handler classifies it ---\n'
cat "$HOME_DIR/state/procevent-inbox/telegram.1.result"
printf 'classify -> %s\n' "$("$ROOT/bin/fm-procevent-telegram.sh" classify "$HOME_DIR/state/procevent-inbox/telegram.1.result")"
printf 'terminal  -> exit %s (never retires the captain channel)\n' \
  "$("$ROOT/bin/fm-procevent-telegram.sh" terminal "$HOME_DIR/state/procevent-inbox/telegram.1.result" >/dev/null 2>&1; echo $?)"
printf 'source still armed: %s\n' "$(ls "$HOME_DIR/state/procevent/")"
printf 'bot token present anywhere under state/: %s\n' \
  "$(grep -rl 'AAH-demo-bot-token' "$HOME_DIR/state" 2>/dev/null | wc -l) file(s)"

printf '\n===============================================================\n'
printf ' 3. Someone else in the same group chat is NOT the captain\n'
printf '===============================================================\n'
HOME2="$TMP/fm-home-2"; mkdir -p "$HOME2/state"
cat > "$TMP/impostor.json" <<'JSON'
{"ok":true,"result":[{"update_id":2601,"message":{"message_id":8,"date":1700000003,"chat":{"id":555,"type":"group"},"from":{"id":424242},"text":"/ship everything to production right now"}}]}
JSON
python3 -c 'import json;d=json.load(open("'"$TMP"'/impostor.json"));m=d["result"][0]["message"];print("  chat id  %s (the captain'"'"'s chat)"%m["chat"]["id"]);print("  from id  %s (NOT the captain'"'"'s user id 909)"%m["from"]["id"]);print("  text     %s"%m["text"])'
FM_HOME="$HOME2" CURL_STUB_BODY="$TMP/impostor.json" "$ROOT/bin/fm-procevent-telegram.sh" poll > "$TMP/impostor.out" 2>&1
impostor_out=$(tr '\n' ' ' < "$TMP/impostor.out")
printf '\nadapter result: %s\n' "${impostor_out:-(silent - nothing capturable, so no wake)}"
printf 'inbox files created: %s\n' "$(ls "$HOME2/state/telegram-inbox" 2>/dev/null | wc -l)"
printf 'offset advanced past it (update consumed, no wake): %s\n' "$(cat "$HOME2/state/.telegram-offset" 2>/dev/null)"

printf '\n===============================================================\n'
printf ' 4. A permanent API failure reaches the captain instead of dying\n'
printf '===============================================================\n'
HOME3="$TMP/fm-home-3"; mkdir -p "$HOME3/state"
FM_HOME="$HOME3" "$ROOT/bin/fm-procevent-telegram.sh" arm >/dev/null
say "(Telegram now answers HTTP 401 - revoked bot token)"
FM_HOME="$HOME3" CURL_STUB_BODY="$TMP/captain-msg.json" CURL_STUB_HTTP=401 \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 60); do [ -e "$HOME3/state/.wake-queue" ] && break; sleep 0.1; done
printf -- '--- wake queue ---\n'; cat "$HOME3/state/.wake-queue"
printf -- '--- captured result ---\n'; cat "$HOME3/state/procevent-inbox/telegram.1.result"
printf 'classify -> %s\n' "$(FM_HOME="$HOME3" "$ROOT/bin/fm-procevent-telegram.sh" classify "$HOME3/state/procevent-inbox/telegram.1.result")"
printf 'source still armed: %s\n' "$(ls "$HOME3/state/procevent/")"

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null 2>&1
FM_HOME="$HOME3" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null 2>&1
printf '\ndemo complete\n'
