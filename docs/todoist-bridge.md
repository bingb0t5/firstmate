# Todoist bridge
The Todoist bridge publishes a read-only view of firstmate work to the captain-facing `Firstmate Board` project.
Todoist is the captain-facing source of truth for board presentation, while the firstmate fleet ledger remains the execution-state source.
n8n is the only cross-writer between the board and firstmate.
A captain comment on a card carries chat-level authority, and completing a card is never approval.

## Configuration
Create the local, gitignored `config/todoist-bridge.env` file with the four values below.
The file is parsed as data and is never sourced as shell.

```text
TODOIST_BRIDGE_PUBLISH_URL=https://example.invalid/publish
TODOIST_BRIDGE_TOKEN=<bearer token>
TODOIST_BRIDGE_REPLIES_URL=https://example.invalid/replies
TODOIST_BRIDGE_ACK_URL=https://example.invalid/ack
```

The token is sent only as an HTTP bearer header and is never printed by the bridge scripts.
When the file is absent, both scripts exit successfully without making a network request and report that the bridge is unconfigured.
The optional `config/todoist-board-hide` file contains one backlog or captain-item key per line.
Blank lines and lines beginning with `#` in the hide file are ignored.

## Payload
`bin/fm-todoist-publish.sh` emits one `fm-board.v1` object to the configured publish URL.
The payload has this shape.

```json
{
  "schema": "fm-board.v1",
  "generated": "<ISO>",
  "items": [
    {
      "key": "<backlog id or cap-key>",
      "title": "",
      "repo": "",
      "kind": "",
      "stage": "Queued|In progress|Validation|UI review|Waiting for captain|Done this week|archive",
      "stage_reason": "",
      "status": "",
      "last_event": "",
      "pr_url": "",
      "worker": "<harness model>",
      "question": "",
      "options": [],
      "default": "",
      "hold_until": "YYYY-MM-DD|null",
      "due": "YYYY-MM-DD|null",
      "deadline": "YYYY-MM-DD|null",
      "blocked": false,
      "labels": []
    }
  ]
}
```

There is one item for each structured backlog record and each live task metadata record, joined by key when both exist.
The latest status-log event loses its `[at=...]` annotation before it is placed in `last_event`.
Dates are retained only when they are valid `YYYY-MM-DD` values.
The `due` date is `hold_until` when present, otherwise a `due:` token in the backlog body.
The `deadline` date comes from a `deadline:` token in the backlog body.
Captain-held items put the hold reason in `question`.
Captain-held `options:` lines accept comma- or pipe-separated choices, and `default:` supplies the recommended choice.

## Stage rules
Done backlog records closed within seven days of the snapshot date use `Done this week`.
Older done backlog records use `archive`.
Captain-held records use `Waiting for captain`.
Other held records use `Queued` and explain the wait in `stage_reason`.
Queued records use `Queued`.
An in-flight task whose current state source is a no-mistakes run step uses `Validation`.
An in-flight task with a failed or blocked current state sets `blocked` to true.
An in-flight task whose current state is done and has a pull request uses `Waiting for captain` until the snapshot evidences that the pull request is merged.
An in-flight task whose current state is done and has a merged pull request uses `Done this week`.
Other in-flight tasks use `In progress`.
An in-flight scout whose key or title contains `review` uses `UI review`.
The `captain` label marks `Waiting for captain` items.
The `blocked` label marks blocked items.
The repository label is included when the item has a repository value.

## Captain replies
`bin/fm-todoist-replies.sh` gets pending events from the replies URL.
Each event must contain `id`, `card_key`, `kind`, `text`, `author`, and `at`.
The script files each unseen event through `bin/fm-inbox.sh note -` as `todoist <card_key> <kind>: <text>`.
The event id is kept in the durable `state/todoist-bridge-replies.seen` file before the acknowledgement is posted.
Seen events are acknowledged again without filing a duplicate note, which repairs a crash between filing and acknowledgement.
Event text is always stdin data and is never interpreted as a command.

## Polling
The operator can register a check script at `state/todoist-bridge.check.sh` with `bin/fm-check-register.sh`.
The check script should run publish every five minutes and replies on every poll.
The check script must finish within `FM_CHECK_TIMEOUT`, print one line only when firstmate should wake, and print nothing otherwise.
The check script should use the configured watcher environment and keep the bridge scripts' exit status visible.

```sh
#!/usr/bin/env bash
set -u
ROOT=/path/to/firstmate
FM_HOME=/path/to/firstmate
export FM_HOME
"$ROOT/bin/fm-todoist-replies.sh" >/dev/null || exit 0
now=$(date +%s)
last_file="$FM_HOME/state/.todoist-bridge-published-at"
last=0
[ -r "$last_file" ] && read -r last <"$last_file"
if [ $((now - last)) -ge 300 ]; then
  "$ROOT/bin/fm-todoist-publish.sh" >/dev/null || exit 0
  printf '%s\n' "$now" >"$last_file"
fi
```

The operator makes the script executable and registers its exact bytes.

```sh
chmod 700 state/todoist-bridge.check.sh
bin/fm-check-register.sh todoist-bridge
```
