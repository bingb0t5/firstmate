#!/usr/bin/env bash
# End-to-end walkthrough of the captain replying path against a fake Telegram
# Bot API that keeps a real conversation for the captain's phone.
set -u
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M1AW0TGP2PFRXC17TST7NA6V
ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
WORK=/tmp/tgdemo/run
rm -rf "$WORK"; mkdir -p "$WORK"
export PATH=/tmp/tgdemo/bin:$PATH
export FAKE_TG_DIR="$WORK/telegram-api"
export FAKE_TG_TOKEN='123456:REAL-LOOKING-BOT-TOKEN-4f9a2c'
export FAKE_TG_CHAT=555
mkdir -p "$FAKE_TG_DIR"

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
tidy() { sed -e "s#$ADAPTER#bin/fm-procevent-telegram.sh#g" -e "s#$WORK/##g" \
    -e 's#FM_HOME=\([a-z]*\) FM_TELEGRAM_ENV_FILE=[^ ]* #FM_HOME=\1 #g'; }
run() { printf '$ %s\n' "$*" | tidy; eval "$@"; local s=$?; [ $s -ne 0 ] && printf '[exit %d]\n' $s; return 0; }

new_home() {
  local home="$WORK/$1"
  mkdir -p "$home/state"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=555\nTELEGRAM_CAPTAIN_USER_ID=909\n' \
    "$FAKE_TG_TOKEN" > "$home.env"
  chmod 600 "$home.env"
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$home.env" "$ADAPTER" arm >/dev/null
  echo "$home"
}

captain_texts() { # update_id message_id text
  python3 - "$FAKE_TG_DIR/inbound.json" "$1" "$2" "$3" <<'PY'
import json, os, sys
path, update_id, message_id, text = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
queue = json.load(open(path)) if os.path.exists(path) else []
queue.append({"update_id": update_id, "message": {"message_id": message_id, "date": 1756900000,
              "chat": {"id": 555}, "from": {"id": 909, "first_name": "Rich"}, "text": text}})
json.dump(queue, open(path, "w"), indent=2)
PY
}

phone() {
  python3 - "$FAKE_TG_DIR" <<'PYX'
import json, os, sys
d = sys.argv[1]

def load(name):
    path = os.path.join(d, name)
    return json.load(open(path)) if os.path.exists(path) else []

events = [("Captain", u["message"]["message_id"], None, u["message"]["text"])
          for u in load("inbound.json")]
events += [("Firstmate", m["message_id"], m["reply_to_message_id"], m["text"])
           for m in load("conversation.json")]
events.sort(key=lambda e: e[1])
quoted = {e[1]: e[3] for e in events}

WIDTH = 64
print("+" + " Captain's phone - Telegram chat 555 ".center(WIDTH, "-") + "+")
for who, mid, reply_to, text in events:
    lines = []
    if reply_to is not None:
        lines.append('re: "%s"' % quoted.get(reply_to, "?")[:40])
    lines += text.splitlines() or [""]
    lines.append("- %s, msg %d" % (who, mid))
    for line in lines:
        if who == "Captain":
            print("|" + ("%s  " % line[:WIDTH - 2]).rjust(WIDTH) + "|")
        else:
            print("|" + ("  %s" % line[:WIDTH - 2]).ljust(WIDTH) + "|")
    print("+" + "-" * WIDTH + "+")
PYX
}

step "1. Captain arms the Telegram source on his home, then texts Firstmate from his phone"
HOME_MAIN=$(new_home main)
captain_texts 5001 771 "Firstmate, how many berths are free in the yard?"
phone

step "2. Firstmate wakes, polls the source, and reads the accepted inbound event"
RESULT="$WORK/result.1"
FM_HOME="$HOME_MAIN" FM_TELEGRAM_ENV_FILE="$HOME_MAIN.env" "$ADAPTER" poll > "$RESULT"
printf '$ fm-procevent-telegram.sh poll\n'; cat "$RESULT"
run "FM_HOME=$HOME_MAIN '$ADAPTER' classify '$RESULT'"
run "FM_HOME=$HOME_MAIN '$ADAPTER' messages '$RESULT'"

step "3. Firstmate answers that exact inbound update; reply text arrives only on stdin"
printf 'Three berths are free: B2, B7 and B11.\n' > "$WORK/response.txt"
printf '$ fm-procevent-telegram.sh reply 5001 < response.txt\n'
FM_HOME="$HOME_MAIN" FM_TELEGRAM_ENV_FILE="$HOME_MAIN.env" "$ADAPTER" reply 5001 < "$WORK/response.txt"
printf '[exit %d]\n' $?

step "4. What the captain sees on his phone: an in-conversation reply to his own message"
phone

step "5. The request Firstmate actually made (destination derived from stored inbound evidence)"
sed 's/^/  /' "$FAKE_TG_DIR/api.calls"
python3 -c "
import json
print(json.dumps(json.load(open('$FAKE_TG_DIR/conversation.json')), indent=2))"

step "6. Repeating the same reply is idempotent and makes no second Telegram call"
before=$(wc -l < "$FAKE_TG_DIR/api.calls")
printf '$ fm-procevent-telegram.sh reply 5001 < response.txt\n'
FM_HOME="$HOME_MAIN" FM_TELEGRAM_ENV_FILE="$HOME_MAIN.env" "$ADAPTER" reply 5001 < "$WORK/response.txt"
printf '[exit %d]\n' $?
printf 'Different text, same update:\n'
printf 'a completely different answer\n' | FM_HOME="$HOME_MAIN" FM_TELEGRAM_ENV_FILE="$HOME_MAIN.env" "$ADAPTER" reply 5001
printf '[exit %d]\n' $?
after=$(wc -l < "$FAKE_TG_DIR/api.calls")
printf 'Telegram API calls before=%s after=%s (no duplicate message on the captain phone)\n' "$before" "$after"

step "7. No proactive or arbitrary-destination send exists"
run "printf 'ping\n' | FM_HOME=$HOME_MAIN FM_TELEGRAM_ENV_FILE=$HOME_MAIN.env '$ADAPTER' reply --chat-id 999 5001 2>&1 | head -6" 
run "printf 'ping\n' | FM_HOME=$HOME_MAIN FM_TELEGRAM_ENV_FILE=$HOME_MAIN.env '$ADAPTER' send 999"
run "printf 'ping\n' | FM_HOME=$HOME_MAIN FM_TELEGRAM_ENV_FILE=$HOME_MAIN.env '$ADAPTER' reply 9999"

step "7b. An inbound record that cannot prove Telegram message identity is refused loudly"
HOME_LEGACY=$(new_home legacy)
python3 - "$WORK/legacy-inbound.json" <<'PYX'
import json, sys
json.dump([{"update_id": 5003, "message": {"date": 1756900100, "chat": {"id": 555},
            "from": {"id": 909}, "text": "sent by an older adapter build"}}], open(sys.argv[1], "w"))
PYX
FAKE_TG_DIR_SAVED=$FAKE_TG_DIR
export FAKE_TG_DIR="$WORK/legacy-api"; mkdir -p "$FAKE_TG_DIR"
cp "$WORK/legacy-inbound.json" "$FAKE_TG_DIR/inbound.json"
FM_HOME="$HOME_LEGACY" FM_TELEGRAM_ENV_FILE="$HOME_LEGACY.env" "$ADAPTER" poll > "$WORK/result.legacy"
run "FM_HOME=$HOME_LEGACY '$ADAPTER' messages $WORK/result.legacy"
printf 'The message is still readable, but a reply to it is refused:\n'
run "printf 'answer\n' | FM_HOME=$HOME_LEGACY FM_TELEGRAM_ENV_FILE=$HOME_LEGACY.env '$ADAPTER' reply 5003"
run "FM_HOME=$HOME_LEGACY '$ADAPTER' doctor | grep -E '^reply_count'"
export FAKE_TG_DIR=$FAKE_TG_DIR_SAVED

step "8. doctor reports honest reply state; the source stays armed and nonterminal"
run "FM_HOME=$HOME_MAIN '$ADAPTER' doctor | grep -E '^(armed|retired|reply_|state=|messages=)'"
run "ls $HOME_MAIN/state/procevent/telegram.source >/dev/null && echo 'Telegram source still registered (channel never retires itself)'"

step "9. Secrecy: the bot token and reply text stay out of state, results and output"
python3 - "$HOME_MAIN" "$FAKE_TG_TOKEN" "$RESULT" <<'PY'
import pathlib, sys
home, token, result = sys.argv[1], sys.argv[2], sys.argv[3]
hits = []
for path in pathlib.Path(home).rglob("*"):
    if path.is_file() and token.encode() in path.read_bytes():
        hits.append(str(path))
print("bot token found in home state files:", hits or "none")
print("result file contents:", pathlib.Path(result).read_text().strip())
body = pathlib.Path(home, "state/telegram/channel.db").read_bytes()
print("reply text stored in database:", b"Three berths are free" in body)
PY

step "10. Transport failure: delivery-unknown, retry refused, never reported as sent"
HOME_UNK=$(new_home unknown)
captain_texts 5002 772 "Are the sails stowed?"
FM_HOME="$HOME_UNK" FM_TELEGRAM_ENV_FILE="$HOME_UNK.env" "$ADAPTER" poll >/dev/null
run "printf 'Yes, stowed at 16:00.\n' | FAKE_TG_FAULT=transport FM_HOME=$HOME_UNK FM_TELEGRAM_ENV_FILE=$HOME_UNK.env '$ADAPTER' reply 5002"
run "printf 'Yes, stowed at 16:00.\n' | FM_HOME=$HOME_UNK FM_TELEGRAM_ENV_FILE=$HOME_UNK.env '$ADAPTER' reply 5002"
run "FM_HOME=$HOME_UNK '$ADAPTER' doctor | grep -E '^reply'"

step "11. Rate limit (HTTP 429): not sent, still owed, names the exact command to re-issue"
HOME_RL=$(new_home ratelimited)
FM_HOME="$HOME_RL" FM_TELEGRAM_ENV_FILE="$HOME_RL.env" "$ADAPTER" poll >/dev/null
run "printf 'Yes, stowed at 16:00.\n' | FAKE_TG_FAULT=429 FM_HOME=$HOME_RL FM_TELEGRAM_ENV_FILE=$HOME_RL.env '$ADAPTER' reply 5002"
run "FM_HOME=$HOME_RL '$ADAPTER' doctor | grep -E '^reply'"
printf 'Operator corrects the condition and re-issues that one command:\n'
run "printf 'Yes, stowed at 16:00.\n' | FM_HOME=$HOME_RL FM_TELEGRAM_ENV_FILE=$HOME_RL.env '$ADAPTER' reply 5002"

step "12. Definite refusal (HTTP 400): durably failed, never retried"
HOME_FAIL=$(new_home definite)
FM_HOME="$HOME_FAIL" FM_TELEGRAM_ENV_FILE="$HOME_FAIL.env" "$ADAPTER" poll >/dev/null
run "printf 'Yes, stowed at 16:00.\n' | FAKE_TG_FAULT=400 FM_HOME=$HOME_FAIL FM_TELEGRAM_ENV_FILE=$HOME_FAIL.env '$ADAPTER' reply 5002"
run "printf 'Yes, stowed at 16:00.\n' | FM_HOME=$HOME_FAIL FM_TELEGRAM_ENV_FILE=$HOME_FAIL.env '$ADAPTER' reply 5002"
run "FM_HOME=$HOME_FAIL '$ADAPTER' doctor | grep -E '^reply'"

step "13. Final state of the captain's phone conversation across the whole run"
phone
