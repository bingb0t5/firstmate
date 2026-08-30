#!/usr/bin/env bash
# End-to-end operator walkthrough of the guarded blocked-migration exit.
# Disposable synthetic home, fake curl transport, no real Telegram state.
set -u

ROOT=${ROOT:?}
ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tg-exit-e2e.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
config=$(cat)
[ -n "${CURL_STUB_CALL_LOG:-}" ] && printf '%s\n' "$config" >> "$CURL_STUB_CALL_LOG"
[ -n "${CURL_STUB_BODY:-}" ] && cat "$CURL_STUB_BODY"
printf '\n%s' "${CURL_STUB_HTTP:-200}"
exit 0
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"
export CURL_STUB_CALL_LOG="$WORK/curl.calls"; : > "$CURL_STUB_CALL_LOG"

HOME_DIR="$WORK/captain-home"
ENV_FILE="$WORK/telegram.env"
mkdir -p "$HOME_DIR/state/telegram-inbox"
printf 'TELEGRAM_BOT_TOKEN=123456:SEKRIT-TEST-TOKEN\nTELEGRAM_CAPTAIN_CHAT_ID=555\nTELEGRAM_CAPTAIN_USER_ID=909\n' > "$ENV_FILE"
chmod 600 "$ENV_FILE"
export FM_HOME="$HOME_DIR" FM_TELEGRAM_ENV_FILE="$ENV_FILE"

# Legacy state exactly as the real blocked captain home: inbox payloads that
# carry no sender identity, so the transactional migration cannot prove them.
printf '0\n' > "$HOME_DIR/state/.telegram-offset"
for id in 3101 3102; do
  printf '{"update_id":%s,"date":1,"chat_id":555,"text":"historical captain text"}\n' "$id" \
    > "$HOME_DIR/state/telegram-inbox/$id.json"
done

say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@" 2>&1; printf '(exit %s)\n' "$?"; }

printf '=== 1. The cutover blocks and mutates nothing ===\n'
run "$ADAPTER" migrate

printf '\n=== 2. The channel announces one blocked notice, which the mate acknowledges ===\n'
say "$ADAPTER poll   # fake transport, empty update batch"
printf '%s\n' '{"ok":true,"result":[]}' > "$WORK/empty.json"
notice=$(CURL_STUB_BODY="$WORK/empty.json" "$ADAPTER" poll); printf '%s\n' "$notice"
printf '%s\n' "$notice" > "$WORK/result.txt"
say "$ADAPTER classify <result>"; "$ADAPTER" classify "$WORK/result.txt"
say "$ADAPTER ack <result>"; "$ADAPTER" ack "$WORK/result.txt"

printf '\n=== 3. The next poll parks silently instead of spinning ===\n'
: > "$CURL_STUB_CALL_LOG"
printf '%s\n' '{"ok":true,"result":[{"update_id":6001,"message":{"date":9,"chat":{"id":555},"from":{"id":909},"text":"ahoy, the channel is back"}}]}' > "$WORK/new.json"
CURL_STUB_BODY="$WORK/new.json" FM_TELEGRAM_POLL_TIMEOUT=1 "$ADAPTER" poll > "$WORK/parked.out" 2>&1 &
parked=$!
sleep 4
if kill -0 "$parked" 2>/dev/null; then
  printf 'parked poll after 4s: still running, produced %s bytes of output, %s Telegram calls\n' \
    "$(wc -c < "$WORK/parked.out")" "$(wc -l < "$CURL_STUB_CALL_LOG")"
else
  printf 'parked poll exited unexpectedly:\n'; cat "$WORK/parked.out"
fi

printf '\n=== 4. doctor shows the bounded non-secret resolution evidence ===\n'
say "$ADAPTER doctor"
doctor=$("$ADAPTER" doctor); printf '%s\n' "$doctor"
fp=$(printf '%s\n' "$doctor" | sed -n 's/^migration_fingerprint=//p')
mf=$(printf '%s\n' "$doctor" | sed -n 's/^migration_resolution_manifest_sha256=//p')
args=()
while IFS= read -r line; do
  p=$(printf '%s' "$line" | cut -d= -f2 | cut -d' ' -f1)
  d=$(printf '%s' "$line" | sed -n 's/.* sha256=\([^ ]*\).*/\1/p')
  args+=(--acknowledge-delivered "$p=sha256:$d")
done < <(printf '%s\n' "$doctor" | grep '^migration_resolution_blocker\.')

printf '\n=== 5. A wrong digest is refused without touching the store ===\n'
run "$ADAPTER" resolve-migration --blocked-fingerprint "$fp" \
  --archive-manifest-sha256 "$mf" \
  --acknowledge-delivered "telegram-inbox/3101.json=sha256:$(printf '0%.0s' {1..64})" \
  "${args[@]:2}"
printf 'migration_status after refusal: %s\n' \
  "$("$ADAPTER" doctor | sed -n 's/^migration_status=//p')"

printf '\n=== 6. The exact acknowledgement commits the guarded exit ===\n'
run "$ADAPTER" resolve-migration --blocked-fingerprint "$fp" \
  --archive-manifest-sha256 "$mf" "${args[@]}"

printf '\n=== 7. The parked poll resumes on its own and delivers real traffic ===\n'
deadline=$((SECONDS + 30))
while kill -0 "$parked" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
wait "$parked" 2>/dev/null; rc=$?
printf 'the same parked poll process (pid %s, backgrounded before the resolution) exited %s with:\n' "$parked" "$rc"
cat "$WORK/parked.out"
cp "$WORK/parked.out" "$WORK/result.txt"
say "$ADAPTER messages <result>"; "$ADAPTER" messages "$WORK/result.txt"
say "$ADAPTER ack <result>"; "$ADAPTER" ack "$WORK/result.txt"

printf '\n=== 8. On a second resolved home, a replayed historical update is never re-delivered ===\n'
HOME_B="$WORK/captain-home-b"
mkdir -p "$HOME_B/state/telegram-inbox"
printf '0\n' > "$HOME_B/state/.telegram-offset"
printf '{"update_id":3101,"date":1,"chat_id":555,"text":"historical captain text"}\n' \
  > "$HOME_B/state/telegram-inbox/3101.json"
(
  export FM_HOME="$HOME_B"
  "$ADAPTER" migrate >/dev/null 2>&1
  notice_b=$(CURL_STUB_BODY="$WORK/empty.json" "$ADAPTER" poll)
  printf '%s\n' "$notice_b" > "$WORK/result-b.txt"
  "$ADAPTER" ack "$WORK/result-b.txt" >/dev/null
  doctor_b=$("$ADAPTER" doctor)
  fp_b=$(printf '%s\n' "$doctor_b" | sed -n 's/^migration_fingerprint=//p')
  mf_b=$(printf '%s\n' "$doctor_b" | sed -n 's/^migration_resolution_manifest_sha256=//p')
  line_b=$(printf '%s\n' "$doctor_b" | grep '^migration_resolution_blocker\.1=')
  p_b=$(printf '%s' "$line_b" | cut -d= -f2 | cut -d' ' -f1)
  d_b=$(printf '%s' "$line_b" | sed -n 's/.* sha256=\([^ ]*\).*/\1/p')
  say "$ADAPTER resolve-migration ... (second home)"
  "$ADAPTER" resolve-migration --blocked-fingerprint "$fp_b" \
    --archive-manifest-sha256 "$mf_b" --acknowledge-delivered "$p_b=sha256:$d_b"
  printf '%s\n' '{"ok":true,"result":[{"update_id":3101,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"historical captain text"}}]}' > "$WORK/replay.json"
  say "$ADAPTER poll   # Telegram replays acknowledged update 3101"
  replay=$(CURL_STUB_BODY="$WORK/replay.json" "$ADAPTER" poll); rc=$?
  printf 'poll exit=%s result=%s\n' "$rc" "${replay:-<no result - the tombstone deduplicated it>}"
  printf 'message notices created: %s | payload-bearing rows for update 3101: %s | committed_offset: %s\n' \
    "$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM notices WHERE kind='message'\").fetchone()[0])" "$HOME_B/state/telegram/channel.db")" \
    "$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('SELECT count(*) FROM messages WHERE update_id=3101 AND payload IS NOT NULL').fetchone()[0])" "$HOME_B/state/telegram/channel.db")" \
    "$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('SELECT committed_offset FROM meta').fetchone()[0])" "$HOME_B/state/telegram/channel.db")"
)

printf '\n=== 9. doctor proves the committed resolution; an exact retry is idempotent ===\n'
say "$ADAPTER doctor"; "$ADAPTER" doctor
run "$ADAPTER" resolve-migration --blocked-fingerprint "$fp" \
  --archive-manifest-sha256 "$mf" "${args[@]}"

printf '\n=== 10. The sealed archive and preserved legacy bytes are untouched ===\n'
archive=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('SELECT migration_archive FROM meta').fetchone()[0])" "$HOME_DIR/state/telegram/channel.db")
printf 'archive=%s\n' "$archive"
(cd "$HOME_DIR/state" && find "$archive" -type f | sort | sed 's/^/  /')
printf 'preserved legacy payload still on disk:\n'
sed 's/^/  /' "$HOME_DIR/state/telegram-inbox/3101.json"
printf 'no absolute home path leaked into doctor: %s\n' \
  "$("$ADAPTER" doctor | grep -c -- "$HOME_DIR") occurrences"
