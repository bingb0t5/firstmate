#!/usr/bin/env bash
# End-to-end demonstration of bin/fm-telegram-brain-capture.sh against a real
# HTTPS "Mr Beanz" that speaks POST /v1/capture. Real curl, real TLS, real
# sockets, real receipts on disk. Nothing about the capture path is mocked:
# only the brain itself and (in step 12) the interrupt adapter that is not in
# this branch are stand-ins.
#
#   usage: e2e_capture_demo.sh <repo-root> <evidence-dir>
set -uo pipefail
exec 2>&1                     # interleave the path's own error lines in place

REPO=${1:?repo root}
EV=${2:?evidence dir}
WORK=$(mktemp -d /tmp/fm-capture-e2e.XXXXXX)
SERVER_PID=""
stop_brain() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'stop_brain; rm -rf "$WORK"' EXIT

CAPTURE="$REPO/bin/fm-telegram-brain-capture.sh"
TOKEN='tok_captain_brain_write_secret'
CAPTAIN_CHAT=4242
GROUP_CHAT=-1001999
STRANGER_CHAT=777001

hr() { printf '\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; }

# --- a self-signed brain, so the https-only credential rule still holds ------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 1 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' >/dev/null 2>&1

export BEANZ_LOG="$WORK/beanz-received.jsonl"
export BEANZ_EXPECT_TOKEN="$TOKEN"
export BEANZ_CERT="$WORK/cert.pem" BEANZ_KEY="$WORK/key.pem"
export BEANZ_PORT_FILE="$WORK/port"
: > "$BEANZ_LOG"

start_brain() {
  stop_brain
  rm -f "$BEANZ_PORT_FILE"
  BEANZ_MODE="$1" python3 "$EV/fake_beanz_brain.py" >"$WORK/brain.err" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 100); do [ -s "$BEANZ_PORT_FILE" ] && break; sleep 0.05; done
  PORT=$(cat "$BEANZ_PORT_FILE")
  [ -n "${FM_BEANZ_ENV_FILE:-}" ] && [ -f "${FM_BEANZ_ENV_FILE:-}" ] \
    && sed -i "s#BEANZ_MCP_URL=.*#BEANZ_MCP_URL=https://localhost:$PORT#" "$FM_BEANZ_ENV_FILE"
  return 0
}

# --- a curl shim that logs every outbound request, then execs the real curl --
mkdir -p "$WORK/shim"
cat > "$WORK/shim/curl" <<'SH'
#!/usr/bin/env bash
cfg=$(mktemp); cat > "$cfg"
sed -n 's/^url = /request-url: /p' "$cfg" >> "$WIRE_LOG"
printf 'argv: %s\n' "$*" >> "$WIRE_LOG"
exec /usr/bin/curl "$@" < "$cfg"
SH
chmod +x "$WORK/shim/curl"
export WIRE_LOG="$WORK/wire.log"
: > "$WIRE_LOG"
export PATH="$WORK/shim:$PATH"
export CURL_CA_BUNDLE="$WORK/cert.pem"

# --- a firstmate home that has never been bootstrapped ----------------------
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/config"        # note: no state/ - capture must bootstrap it
export FM_HOME="$HOME_DIR"
export FM_BEANZ_ENV_FILE="$WORK/mcp.env"
export FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT"

start_brain ok

payload() { # update_id text chat_id
  python3 - "$@" <<'PY'
import json, sys
print(json.dumps({"update_id": int(sys.argv[1]), "text": sys.argv[2],
                  "chat_id": int(sys.argv[3]), "date": 1756100000,
                  "from_id": 909}, sort_keys=True))
PY
}

hr "1. doctor on a home that has never configured capture"
run "fm-telegram-brain-capture.sh doctor"
"$CAPTURE" doctor

hr "2. the captain drops in the brain credential file, then re-checks readiness"
umask 077
cat > "$FM_BEANZ_ENV_FILE" <<EOF
BEANZ_MCP_TOKEN=$TOKEN
BEANZ_MCP_URL=https://localhost:$PORT
EOF
chmod 600 "$FM_BEANZ_ENV_FILE"
run "fm-telegram-brain-capture.sh doctor"
"$CAPTURE" doctor

hr "3. capture a batch of canonical Telegram JSON lines from the interrupt adapter"
BATCH="$WORK/batch.jsonl"
{
  payload 5001 'Remember: the homestay partner signs Thursday - café ☕ deal is on' "$CAPTAIN_CHAT"
  payload 5002 'group chatter about the roadmap' "$GROUP_CHAT"
  payload 5003 'hello from a stranger DM' "$STRANGER_CHAT"
  payload 5004 "$(printf 'two paragraphs, one Telegram message: second paragraph')" "$CAPTAIN_CHAT"
} > "$BATCH"
run "cat batch.jsonl"
cat "$BATCH"
run "fm-telegram-brain-capture.sh capture batch.jsonl"
"$CAPTURE" capture "$BATCH"; printf 'exit=%d\n' $?

hr "4. what Mr Beanz actually received on the wire"
run "cat beanz-received.jsonl"
python3 - "$BEANZ_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    print(json.dumps(json.loads(line), ensure_ascii=False, indent=2, sort_keys=True))
PY

hr "5. the captured text is byte-exact against the payload the adapter emitted"
python3 - "$BATCH" "$BEANZ_LOG" <<'PY'
import json, sys
sent = {json.loads(l)["update_id"]: json.loads(l)["text"] for l in open(sys.argv[1], encoding="utf-8")}
got = [json.loads(l)["body"]["text"] for l in open(sys.argv[2], encoding="utf-8")]
for update_id, text in sorted(sent.items()):
    if text in got:
        print("update %d  bytes match: %r" % (update_id, text.encode("utf-8")))
PY

hr "6. the durable receipt this home now holds"
run "ls -la state/telegram-brain-capture && cat state/telegram-brain-capture/5001"
ls -la "$HOME_DIR/state/telegram-brain-capture"
echo
cat "$HOME_DIR/state/telegram-brain-capture/5001"; echo

hr "7. replay of the identical batch (the Telegram ack was lost)"
before=$(wc -l < "$BEANZ_LOG")
run "fm-telegram-brain-capture.sh capture batch.jsonl"
"$CAPTURE" capture "$BATCH"; printf 'exit=%d\n' $?
printf 'brain writes during the replay: %d\n' "$(( $(wc -l < "$BEANZ_LOG") - before ))"

hr "8. the captain turns group discussion on"
run "printf 'on\\n' > config/telegram-brain-capture-group && fm-telegram-brain-capture.sh doctor"
printf 'on\n' > "$HOME_DIR/config/telegram-brain-capture-group"
"$CAPTURE" doctor
run "fm-telegram-brain-capture.sh capture batch.jsonl"
"$CAPTURE" capture "$BATCH"; printf 'exit=%d\n' $?
run "tail -1 beanz-received.jsonl   # group text lands under its own source name"
tail -1 "$BEANZ_LOG"

hr "9. the brain goes down mid-conversation: no ack, nothing lost"
start_brain 500
OUTAGE="$WORK/outage.jsonl"
{
  payload 6001 'decision: we ship the capture half first' "$CAPTAIN_CHAT"
  payload 6002 'promise: I will call the accountant Friday' "$CAPTAIN_CHAT"
  payload 6003 'idea: fold the digest into the morning brief' "$CAPTAIN_CHAT"
} > "$OUTAGE"
run "fm-telegram-brain-capture.sh capture outage.jsonl   # brain returns 500"
"$CAPTURE" capture "$OUTAGE"; printf 'exit=%d\n' $?
run "ls state/telegram-brain-capture   # no receipt for any 6xxx payload"
ls "$HOME_DIR/state/telegram-brain-capture"

hr "10. the retry that the withheld Telegram ack guarantees"
start_brain ok
run "fm-telegram-brain-capture.sh capture outage.jsonl"
"$CAPTURE" capture "$OUTAGE"; printf 'exit=%d\n' $?
run "the memories Mr Beanz now holds, in the order it accepted them"
python3 - "$BEANZ_LOG" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    rec = json.loads(line)
    if rec["accepted"]:
        print("%-26s %s" % (rec["body"]["source"], rec["body"]["text"].replace("\u2028", "<U+2028>")))
PY

hr "11. an unusable receipt store refuses the whole batch before any brain write"
chmod 0755 "$HOME_DIR/state/telegram-brain-capture"
run "chmod 0755 state/telegram-brain-capture && fm-telegram-brain-capture.sh doctor"
"$CAPTURE" doctor
WEDGED="$WORK/wedged.jsonl"
{ payload 7001 'one' "$CAPTAIN_CHAT"; payload 7002 'two' "$CAPTAIN_CHAT"; payload 7003 'three' "$CAPTAIN_CHAT"; } > "$WEDGED"
before=$(wc -l < "$BEANZ_LOG")
run "fm-telegram-brain-capture.sh capture wedged.jsonl"
"$CAPTURE" capture "$WEDGED"; printf 'exit=%d\n' $?
printf 'brain writes attempted during the refusal: %d\n' "$(( $(wc -l < "$BEANZ_LOG") - before ))"
chmod 0700 "$HOME_DIR/state/telegram-brain-capture"

hr "12. a bad capture timeout is refused in the same pre-flight"
run "FM_BEANZ_CAPTURE_TIMEOUT=0 fm-telegram-brain-capture.sh capture wedged.jsonl"
FM_BEANZ_CAPTURE_TIMEOUT=0 "$CAPTURE" capture "$WEDGED"; printf 'exit=%d\n' $?

hr "13. composing with the interrupt adapter: from-result"
mkdir -p "$WORK/adapterbin"
cat > "$WORK/adapterbin/fm-procevent-telegram.sh" <<ADP
#!/usr/bin/env bash
# Stand-in for the in-flight interrupt/wake adapter, which is not in this
# branch. It answers the same two questions capture asks of it.
printf '%s %s\n' "\$1" "\$2" >> "$WORK/adapter.calls"
case "\$1" in
  classify) echo message ;;
  messages) cat "$WORK/result.messages.jsonl" ;;
  *) exit 2 ;;
esac
ADP
chmod +x "$WORK/adapterbin/fm-procevent-telegram.sh"
payload 8001 'from the interrupt result: book the flights' "$CAPTAIN_CHAT" > "$WORK/result.messages.jsonl"
echo '{"kind":"message"}' > "$WORK/result.json"
run "PATH=adapterbin:\$PATH fm-telegram-brain-capture.sh from-result result.json"
PATH="$WORK/adapterbin:$PATH" "$CAPTURE" from-result "$WORK/result.json"; printf 'exit=%d\n' $?
run "tail -1 beanz-received.jsonl"
tail -1 "$BEANZ_LOG"
run "every call this path made to the interrupt adapter"
sed "s#$WORK#<work>#g" "$WORK/adapter.calls"

hr "14. every outbound request this path made, start to finish"
run "cat wire.log   # only the configured brain origin"
sed -e "s#localhost:[0-9]*#localhost:<port>#g" -e "s#$WORK#<work>#g" "$WIRE_LOG"
printf '\nrequests to api.telegram.org: %d\n' "$(grep -c 'api\.telegram\.org' "$WIRE_LOG")"
printf 'getUpdates / offset advances: %d\n' "$(grep -c -i 'getupdates\|offset' "$WIRE_LOG")"
printf 'brain token anywhere in the logged curl argv: %d\n' "$(grep -c -- "$TOKEN" "$WIRE_LOG")"
