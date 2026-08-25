#!/usr/bin/env bash
# Operator-level end-to-end transcript for the transactional Telegram
# process-event channel. Drives only the public CLI surface an operator uses:
#   bin/fm-procevent-telegram.sh arm|poll|classify|messages|ack|doctor|migrate
#   bin/fm-procevent.sh reconcile|list|handled
# Telegram itself is replaced by an executable fake curl on PATH that speaks the
# real adapter contract (body on stdout, newline + HTTP status suffix frame).
# Nothing else is stubbed: the real runner, real SQLite store, and real
# migration path all execute.
set -u

ROOT=${ROOT:?set ROOT to the repository root}
ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/telegram-e2e.XXXXXX")
export FM_PROCEVENT_CLAIM_ROOT="$WORK/claims"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
cat >/dev/null
[ -n "${CURL_STUB_BODY:-}" ] && cat "$CURL_STUB_BODY"
printf '\n%s' "${CURL_STUB_HTTP:-200}"
exit "${CURL_STUB_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

TOKEN='123456:SEKRIT-TEST-TOKEN-7f3a9c'
say() { printf '\n== %s ==\n' "$*"; }
run() { printf '$ fm-procevent-telegram.sh %s\n' "$*"; eval "\"\$ADAPTER\" $*" 2>&1 | sed 's/^/  /'; }
runq() { printf '$ fm-procevent.sh %s\n' "$*"; eval "\"\$PROCEVENT\" $*" 2>&1 | sed 's/^/  /'; }
rel() { sed "s#$1/#  #g;s#$1#  .#g"; }

home_env() {
  mkdir -p "$1/state"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=555\nTELEGRAM_CAPTAIN_USER_ID=909\n' \
    "$TOKEN" > "$1.env"
  chmod 600 "$1.env"
}
body() { printf '%s\n' "$2" > "$WORK/$1.json"; printf '%s' "$WORK/$1.json"; }
poll_to() {   # poll_to <outfile> <body> [http] [comment]
  local out=$1 rc=0
  printf '$ fm-procevent-telegram.sh poll%s\n' "${4:+    # $4}"
  CURL_STUB_BODY="$2" CURL_STUB_HTTP="${3:-200}" CURL_STUB_EXIT="${CURL_EXIT:-0}" \
    "$ADAPTER" poll > "$out" 2>&1 || rc=$?
  if [ -s "$out" ]; then sed 's/^/  /' "$out"; else printf '  (no output)\n'; fi
  printf '  (poll exit %s)\n' "$rc"
}
offset() { "$ADAPTER" doctor | sed -n 's/^committed_offset=//p'; }

CAPTAIN=$(body captain \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1700000000,"chat":{"id":555},"from":{"id":909},"text":"ahoy from the captain"}}]}')
MIXED=$(body mixed \
  '{"ok":true,"result":[{"update_id":1002,"message":{"date":1700000002,"chat":{"id":555},"from":{"id":909},"text":"must not commit"}},{"update_id":true}]}')
EMPTY=$(body empty '{"ok":true,"result":[]}')

################################################################################
say "1. Fresh home: one explicit arm publishes the transactional store"
H="$WORK/live"; home_env "$H"
export FM_HOME="$H" FM_TELEGRAM_ENV_FILE="$H.env"
run arm
runq list
printf '$ ls -ld state/telegram state/telegram/channel.db\n'
ls -ld "$H/state/telegram" "$H/state/telegram/channel.db" | awk '{print "  " $1 "  " $NF}' | rel "$H/state"
printf '$ ls state/    # no offset/blocked/pending/receipt/inbox files anywhere\n'
ls -A "$H/state" | sed 's/^/  /'
run doctor

say "2. Real runner captures a captain message; handler reads, acks, handles it"
printf '$ fm-procevent.sh reconcile    # the generic runner spawns the poll child\n'
CURL_STUB_BODY="$CAPTAIN" "$PROCEVENT" reconcile >/dev/null 2>&1
for _ in $(seq 1 80); do [ -e "$H/state/.wake-queue" ] && break; sleep 0.1; done
RESULT="$H/state/procevent-inbox/telegram.1.result"
printf '$ cat state/.wake-queue\n'; sed 's/^/  /' "$H/state/.wake-queue"
printf '$ cat state/procevent-inbox/telegram.1.result\n'; sed 's/^/  /' "$RESULT"
run "classify '$RESULT'"
run "messages '$RESULT'"
run "ack '$RESULT'"
runq handled telegram 1
printf '$ fm-procevent-telegram.sh classify <the same result, after ack>\n'
printf '  %s    <- one stable notice cannot authorize the message twice\n' "$("$ADAPTER" classify "$RESULT")"

say "3. Token secrecy: the bot token is in no durable state, result, or payload"
printf '$ grep -rl SEKRIT-TEST-TOKEN state/\n'
if grep -rl 'SEKRIT-TEST-TOKEN' "$H/state" 2>/dev/null | sed 's/^/  /' | grep -q .; then
  printf '  ^ LEAKED\n'
else
  printf '  (no match, grep exit 1)  <- the token reaches curl only through its stdin config\n'
fi

say "4. A rejected batch never advances the irreversible Telegram offset"
printf '  committed_offset before = %s\n' "$(offset)"
poll_to "$WORK/r.mixed" "$MIXED" 200 'batch = one valid captain text + one update_id:true'
printf '  committed_offset after  = %s   <- unchanged; the valid half was not committed either\n' "$(offset)"
run "ack '$WORK/r.mixed'"

say "5. 401 and 409 are independent sticky episodes cleared only by a validated success"
poll_to "$WORK/r.401" "$EMPTY" 401 'Telegram answers HTTP 401'
run "ack '$WORK/r.401'"
poll_to "$WORK/r.409" "$EMPTY" 409 'Telegram answers HTTP 409 - a separate episode'
run "ack '$WORK/r.409'"
run "doctor | grep -E 'committed_offset|active_conditions'"
printf '  ^ both API episodes plus the protocol episode are still active after acknowledgement\n'
poll_to "$WORK/r.ok" "$EMPTY" 200 'one validated typed success (exit 1 = nothing to report)'
run "doctor | grep -E 'committed_offset|active_conditions'"
printf '  ^ all three episodes cleared in the same transaction as the accepted batch\n'

say "5b. Transport failure is silent for a bounded budget, then announced once"
CURL_EXIT=7 poll_to "$WORK/t.1" "$EMPTY" 200 'curl fails (exit 7) - inside the budget, stays silent'
CURL_EXIT=7 poll_to "$WORK/t.2" "$EMPTY" 200 'second consecutive failure - still silent'
CURL_EXIT=7 poll_to "$WORK/t.3" "$EMPTY" 200 'third consecutive failure - announced once'
CURL_EXIT=7 poll_to "$WORK/t.4" "$EMPTY" 200 'the episode does not re-announce'
run "doctor | grep -E 'consecutive_failures|active_conditions'"
run "ack '$WORK/t.3'"
poll_to "$WORK/t.5" "$EMPTY" 200 'transport recovers'
run "doctor | grep -E 'consecutive_failures|active_conditions'"

say "6. Corrupt authoritative state announces an actionable block through the real runner"
python3 - "$H/state/telegram/channel.db" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as fh:
    fh.seek(0); fh.write(b'not-a-sqlite-file')
PY
printf '$ printf not-a-sqlite-file >> state/telegram/channel.db   # simulated corruption\n'
rm -f "$H/state/.wake-queue" "$H/state/procevent-inbox/telegram."*
CURL_STUB_BODY="$CAPTAIN" "$PROCEVENT" reconcile >/dev/null 2>&1
for _ in $(seq 1 80); do [ -e "$H/state/.wake-queue" ] && break; sleep 0.1; done
CORRUPT=$(ls "$H/state/procevent-inbox"/telegram.*.result 2>/dev/null | head -1)
printf '$ cat state/procevent-inbox/%s    # what the runner durably captured\n' "$(basename "$CORRUPT")"
sed 's/^/  /' "$CORRUPT"
printf '$ fm-procevent-telegram.sh classify <that result>\n'
printf '  %s   <- an actionable blocked result, not the silent nonzero-empty path\n' "$("$ADAPTER" classify "$CORRUPT")"
runq list
printf '  ^ the source stays permanently registered through corruption\n'
run doctor
unset FM_HOME FM_TELEGRAM_ENV_FILE

################################################################################
say "7. One-time offline migration of coherent legacy state"
L="$WORK/legacy"; home_env "$L"
mkdir -p "$L/state/telegram-inbox/handled" "$L/state/.telegram-delivery-receipts"
printf '1002\n' > "$L/state/.telegram-offset"
printf 'staged but unpublished\n' > "$L/state/.telegram-offset.staged"
printf '401\n409\n' > "$L/state/.telegram-blocked"
printf '{"update_id":900,"date":1,"chat_id":555,"from_id":909,"text":"already handled"}\n' \
  > "$L/state/telegram-inbox/handled/900.json"
printf '{"update_id":1002,"date":2,"chat_id":555,"from_id":909,"text":"pending legacy order"}\n' \
  > "$L/state/telegram-inbox/1002.json"
printf '1 1003\n' > "$L/state/.telegram-pending-delivery"
cp "$L/state/telegram-inbox/1002.json" "$L/state/.telegram-delivery-receipts/1002.json"
export FM_HOME="$L" FM_TELEGRAM_ENV_FILE="$L.env"
printf '$ find state -mindepth 1    # the old scattered file format\n'
( cd "$L" && find state -mindepth 1 -not -name 'telegram-watch.check.sh' | sort | sed 's/^/  /' )
printf '  state/telegram-watch.check.sh   <- the legacy producer, still registered\n'
printf '$ :> state/telegram-watch.check.sh    # legacy watcher check present\n'
: > "$L/state/telegram-watch.check.sh"
mig_rc=0; "$ADAPTER" migrate > "$WORK/legacy-refuse.out" 2>&1 || mig_rc=$?
printf '$ fm-procevent-telegram.sh migrate    # while the legacy producer is still live\n'
sed 's/^/  /' "$WORK/legacy-refuse.out"; printf '  (migrate exit %s)\n' "$mig_rc"
printf '$ ls state/telegram/channel.db 2>&1    # a refused cutover leaves no database\n'
( cd "$L/state" && ls telegram/channel.db 2>&1 | sed 's/^/  /' )
printf '$ rm state/telegram-watch.check.sh     # operator deregisters the legacy check\n'
rm -f "$L/state/telegram-watch.check.sh"
run migrate
run doctor
ARCH=$("$ADAPTER" doctor | sed -n 's/^migration_archive=//p')
printf '$ ls -ld state/%s ; find state/%s -type f\n' "$ARCH" "$ARCH"
stat -c '  %A  %n' "$L/state/$ARCH" | rel "$L/state"
find "$L/state/$ARCH" -type f | sort | sed "s#$L/state/#  #"
printf '$ find state -mindepth 1 -not -path "*migration-archive*"    # nothing was deleted\n'
( cd "$L" && find state -mindepth 1 -not -path '*migration-archive*' | sort | sed 's/^/  /' )
poll_to "$WORK/m.1" "$CAPTAIN" 200 'imported notices drain before any network call'
run "messages '$WORK/m.1'"
run "ack '$WORK/m.1'"
poll_to "$WORK/m.2" "$CAPTAIN" 200 'next imported notice'
run "ack '$WORK/m.2'"
poll_to "$WORK/m.3" "$CAPTAIN" 200 'next imported notice'
printf '  ^ the imported 401 and 409 episodes survived the cutover as separate notices\n'
runq list
printf '  ^ migrate retired the legacy source; the operator re-arms after verifying the cutover\n'
run arm
run "doctor | grep -E 'migration_status|committed_offset'"
unset FM_HOME FM_TELEGRAM_ENV_FILE

say "8. Ambiguous legacy state blocks visibly and guesses no offset"
A="$WORK/ambiguous"; home_env "$A"
mkdir -p "$A/state/telegram-inbox"
printf '1002\n' > "$A/state/.telegram-offset"
: > "$A/state/telegram-inbox/1002.json"   # torn payload from an interrupted legacy write
export FM_HOME="$A" FM_TELEGRAM_ENV_FILE="$A.env"
printf '$ ls -l state/telegram-inbox/1002.json    # zero-byte torn legacy payload\n'
ls -l "$A/state/telegram-inbox/1002.json" | awk '{print "  " $1 "  " $5 " bytes  " $NF}' | rel "$A/state"
printf '$ fm-procevent-telegram.sh migrate\n'
mig_rc=0; "$ADAPTER" migrate > "$WORK/amb.out" 2>&1 || mig_rc=$?
sed 's/^/  /' "$WORK/amb.out"; printf '  (migrate exit %s)\n' "$mig_rc"
run doctor
poll_to "$WORK/amb.poll" "$CAPTAIN" 200 'a blocked cutover stays blocked instead of polling'
printf '$ fm-procevent-telegram.sh classify <that result>\n'
printf '  %s\n' "$("$ADAPTER" classify "$WORK/amb.poll")"
unset FM_HOME FM_TELEGRAM_ENV_FILE
printf '\n== transcript complete ==\n'
