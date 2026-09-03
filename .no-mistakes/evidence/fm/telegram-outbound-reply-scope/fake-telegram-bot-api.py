#!/usr/bin/env python3
"""Fake Telegram Bot API reachable through curl's command-line contract.

Keeps a durable conversation for the captain's phone: getUpdates hands out
queued inbound messages, sendMessage appends the bot's answer to the same
conversation and returns the Message object Telegram would return.
"""
import json
import os
import re
import sys
import urllib.parse

DIR = os.environ["FAKE_TG_DIR"]
TOKEN = os.environ["FAKE_TG_TOKEN"]
CHAT = int(os.environ["FAKE_TG_CHAT"])


def load(name, default):
    path = os.path.join(DIR, name)
    if not os.path.exists(path):
        return default
    with open(path) as handle:
        return json.load(handle)


def save(name, value):
    with open(os.path.join(DIR, name), "w") as handle:
        json.dump(value, handle, indent=2)


config = sys.stdin.read()
url = re.search(r'url = "([^"]+)"', config).group(1)
argv = sys.argv[1:]
write_format = argv[argv.index("-w") + 1] if "-w" in argv else ""

with open(os.path.join(DIR, "api.calls"), "a") as handle:
    handle.write(re.sub(re.escape(TOKEN), "<BOT-TOKEN>", url) + "\n")

match = re.match(r"https://api\.telegram\.org/bot([^/]+)/(\w+)", url)
token, method = match.group(1), match.group(2)


def respond(status, body):
    sys.stdout.write(body)
    sys.stdout.write(write_format.replace("\\n", "\n").replace("%{http_code}", str(status)))
    sys.exit(0)


if token != TOKEN:
    respond(401, json.dumps({"ok": False, "error_code": 401, "description": "Unauthorized"}))

if method == "getUpdates":
    offset = int(urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["offset"][0])
    queue = load("inbound.json", [])
    pending = [u for u in queue if u["update_id"] >= offset]
    respond(200, json.dumps({"ok": True, "result": pending}))

if method == "sendMessage":
    fault = os.environ.get("FAKE_TG_FAULT", "")
    data_fd = argv[argv.index("--data-binary") + 1]
    with open(data_fd.lstrip("@"), "rb") as handle:
        request = urllib.parse.parse_qs(handle.read().decode("utf-8"), strict_parsing=True)
    if fault == "transport":
        sys.exit(7)  # curl exit 7: could not connect
    if fault in ("429", "401", "400"):
        respond(int(fault), json.dumps({"ok": False, "error_code": int(fault),
                                        "description": "fault injected"}))
    chat_id = int(request["chat_id"][0])
    reply_to = json.loads(request["reply_parameters"][0])["message_id"]
    text = request["text"][0].strip()  # Telegram trims the sent text
    conversation = load("conversation.json", [])
    next_id = max([m["message_id"] for m in conversation] + [8800]) + 1
    conversation.append({"message_id": next_id, "from": "Firstmate (bot)",
                         "chat_id": chat_id, "reply_to_message_id": reply_to, "text": text})
    save("conversation.json", conversation)
    respond(200, json.dumps({"ok": True, "result": {
        "message_id": next_id,
        "chat": {"id": chat_id},
        "reply_to_message": {"message_id": reply_to},
        "text": text,
    }}))

respond(404, json.dumps({"ok": False, "error_code": 404, "description": "Not Found"}))
