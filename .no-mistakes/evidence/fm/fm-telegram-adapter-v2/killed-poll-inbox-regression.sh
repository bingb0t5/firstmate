#!/usr/bin/env bash
# Kill a real poll between its temp payload write and the hardlink claim, then
# show what a handler that follows the documented instruction ("read every new
# file under state/telegram-inbox") would actually see.
#
# $1 = adapter to exercise
set -u
ADAPTER=$1
LABEL=$2
DEMO=$(mktemp -d /tmp/tgkill.XXXXXX)
FM_HOME="$DEMO/home"; mkdir -p "$FM_HOME/state" "$DEMO/bin" "$DEMO/api"
ENV_FILE="$DEMO/telegram.env"
printf 'TELEGRAM_BOT_TOKEN=t\nTELEGRAM_CAPTAIN_CHAT_ID=555\nTELEGRAM_CAPTAIN_USER_ID=909\n' > "$ENV_FILE"
chmod 600 "$ENV_FILE"

cat > "$DEMO/bin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=""; i=1; args=("$@")
while [ "$i" -le "$#" ]; do
  [ "${args[$((i - 1))]}" = "-o" ] && out=${args[$i]}
  i=$((i + 1))
done
cat > /dev/null
[ -n "$out" ] && cp "$TG_BODY" "$out"
printf '200'
SH
chmod +x "$DEMO/bin/curl"
export PATH="$DEMO/bin:$PATH" FM_HOME FM_TELEGRAM_ENV_FILE="$ENV_FILE"

# A realistic backlog: the captain fired off a burst of messages while the
# crew was away, so one poll writes several payloads in a row.
{
  printf '{"ok":true,"result":['
  for i in $(seq 1 40); do
    [ "$i" -gt 1 ] && printf ','
    printf '{"update_id":%d,"message":{"date":%d,"chat":{"id":555},"from":{"id":909},"text":"captain order %d: deploy now"}}' \
      "$((7000 + i))" "$i" "$i"
  done
  printf ']}'
} > "$DEMO/api/burst.json"
export TG_BODY="$DEMO/api/burst.json"

INBOX="$FM_HOME/state/telegram-inbox"
mkdir -p "$INBOX"

setsid "$ADAPTER" poll >/dev/null 2>&1 &
child=$!
# Busy-watch for the first temp payload the poll creates anywhere, then kill
# the whole process group hard - exactly what fm-procevent.sh does on
# retire/stop (kill -TERM -"$pid"), only less survivable.
killed=no
for _ in $(seq 1 200000); do
  if compgen -G "$INBOX/.*tmp*" > /dev/null || compgen -G "$FM_HOME/state/.telegram-delivery-receipts/tmp.*" > /dev/null; then
    kill -9 -"$child" 2>/dev/null && killed=yes
    break
  fi
  kill -0 "$child" 2>/dev/null || break
done
wait "$child" 2>/dev/null

printf '\n--- %s ---\n' "$LABEL"
printf 'poll killed mid-write: %s\n' "$killed"
printf 'offset file: %s\n' "$(cat "$FM_HOME/state/.telegram-offset" 2>/dev/null || echo '(absent - nothing was ever acknowledged to Telegram)')"
printf 'what the handler sees when it scans state/telegram-inbox:\n'
found=$(cd "$INBOX" && find . -mindepth 1 -maxdepth 1 -type f | sed 's|^\./||' | sort)
if [ -z "$found" ]; then
  printf '  (nothing - clean)\n'
else
  printf '%s\n' "$found" | sed 's/^/  /'
fi
unclaimed=$(printf '%s\n' "$found" | grep -c 'tmp' || true)
printf 'unclaimed temp payloads visible to the handler: %s\n' "$unclaimed"
for f in $(printf '%s\n' "$found" | grep 'tmp' || true); do
  printf '  contents of %s:\n    %s\n' "$f" "$(cat "$INBOX/$f")"
done
rm -rf "$DEMO"
