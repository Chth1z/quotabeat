#!/usr/bin/env bash
# quotabeat's tests. Each runs quotabeat.sh as Claude Code does (JSON on stdin; exit code, stdout and stderr read
# back) against a config folder of its own; QUOTABEAT_UNIT=1 makes a minute last one second.
#
#   bash tests/run.sh

cd "$(dirname "$0")/.." || exit 1
QB=$PWD/quotabeat.sh
PASS=0 FAIL=0
BEAT_NOTE='heartbeat: reply with exactly . and nothing else.'
RESET_NOTE='The 5-hour window has reset: go on with the paused work.'

is() { if [[ $2 == "$3" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi; }
has() { if [[ $2 == *"$3"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  want: ...%s...\n  got:  %s\n' "$1" "$3" "$2"; fi; }

setup() {
  [[ -n ${T:-} ]] && rm -rf "$T"
  T=$(mktemp -d)
  export CLAUDE_CONFIG_DIR=$T QUOTABEAT_UNIT=1
  unset CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID
  printf '{\n  "numStartups": 3,\n  "oauthAccount": {\n    "accountUuid": "acct-t",\n    "emailAddress": "x@y"\n  }\n}\n' > "$T/.claude.json"
  mkdir -p "$T/projects/p"
  TR=$T/projects/p/s1.jsonl
  : > "$TR"
  NOW=$(date +%s)
}
sl() {  # sl <5h %> <5h reset> [<7d %> <7d reset>]: one status line run
  local rl="\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$2}"
  [[ -n ${3:-} ]] && rl+=",\"seven_day\":{\"used_percentage\":$3,\"resets_at\":$4}"
  printf '{"session_id":"s1","context_window":{"total_input_tokens":5,"current_usage":{"input_tokens":2},"used_percentage":12,"remaining_percentage":88},"rate_limits":{%s},"vim":{"mode":"NORMAL"}}\n' "$rl" |
    bash "$QB" statusline
}
arm() { CLAUDE_CODE_SESSION_ID=s1 bash "$QB" arm "$@"; }
input() { printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","hook_event_name":"%s"%s}' "$TR" "$T" "$1" "${2:-}"; }
post() {  # a tool ran: the async PostToolUse hook's stderr and exit code
  OUT=$(input PostToolUse ',"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}' | bash "$QB" hook 2>&1)
  CODE=$?
}
prompt() { input UserPromptSubmit ',"prompt":"hi"' | bash "$QB" hook; }
state() { cat "$T/quotabeat/s1"; }
# 0 m5, 1 m7, 2 beat, 3 idle, 4 active, 5 since, 6 gen, 7 wake, 8 acct, 9 desk, 10 armed, 11 asked, 12 noticed
field() { local f; read -ra f < "$T/quotabeat/s1"; echo "${f[$1]}"; }
set_field() { local f; read -ra f < "$T/quotabeat/s1"; f[$1]=$2; echo "${f[*]}" > "$T/quotabeat/s1"; }
stop_bg() {  # the turn ends: its Stop hook runs in the background
  input Stop ',"stop_hook_active":false,"last_assistant_message":"done","background_tasks":[],"session_crons":[]' |
    bash "$QB" hook 2> "$T/stop.err" &
  PID=$!
}
waiter() { for _ in $(seq 1 80); do [[ $(field 6) == "$PID" ]] && return 0; sleep 0.1; done; return 1; }  # its timer waits

# --- the status line and the readings

setup
is "status line" "$(sl 23.5 $((NOW + 3600)) 41.2 $((NOW + 3 * 86400)))" "5h 23% ($(date -d @$((NOW + 3600)) +%H:%M)) | 7d 41% ($(LC_ALL=C date -d @$((NOW + 3 * 86400)) '+%a %H:%M')) | ctx 12%"
read -r t w1 w2 < "$T/quotabeat/usage-acct-t"
is "reading" "$w1 $w2" "five_hour:23.5:$((NOW + 3600)) seven_day:41.2:$((NOW + 3 * 86400))"
sl 40 $((NOW + 3600)) > /dev/null
sl 30 $((NOW + 3605)) > /dev/null
has "within a window the larger stands" "$(cat "$T/quotabeat/usage-acct-t")" "five_hour:40:"
has "a window missing from a response keeps its reading" "$(cat "$T/quotabeat/usage-acct-t")" "seven_day:41.2:"
sl 5 $((NOW + 5 * 3600)) > /dev/null
has "a later window replaces an earlier one" "$(cat "$T/quotabeat/usage-acct-t")" "five_hour:5:"
sl 90 $((NOW + 3600)) > /dev/null
has "an earlier window never comes back" "$(cat "$T/quotabeat/usage-acct-t")" "five_hour:5:"
CLAUDE_CODE_ACCOUNT_UUID=acct-d sl 70 $((NOW + 3600)) > /dev/null
has "each account has its own reading" "$(cat "$T/quotabeat/usage-acct-d")" "five_hour:70:"
has "and leaves the others alone" "$(cat "$T/quotabeat/usage-acct-t")" "five_hour:5:"
setup
sl 50 $((NOW + 3600)) 41 $((NOW + 86400)) > /dev/null
is "a window Claude Code no longer sends keeps its place" "$(sl 9 $((NOW - 10)) | cut -d'|' -f1)" "5h 50% ($(date -d @$((NOW + 3600)) +%H:%M)) "
setup
is "a reset window reads 0" "$(sl 9 $((NOW - 10)) | cut -d'|' -f1)" "5h 0% "

# --- arming

setup
sl 6 $((NOW + 3600)) 94 $((NOW + 86400)) > /dev/null
has "arm: defaults" "$(arm)" "quotabeat on: stop at 87% of the 5-hour window and 97% of the weekly; a heartbeat every 47 minutes while the session waits: 7 after a stop, all the way through a quota pause when that costs less than a cold cache. Usage now: 5h 6%"
is "arm: state" "$(state)" "87 97 47 7 1 0 0 0 acct-t 0 $(field 10) 0 -"
has "arm: the status line shows the marks" "$(sl 6 $((NOW + 3600)))" "| guard 87/97"
arm 80 90 > /dev/null; is "arm: two numbers" "$(field 0) $(field 1)" "80 90"
arm 85% > /dev/null; is "arm: one number, a percent sign" "$(field 0) $(field 1)" "85 97"
arm week=off Beat=30 IDLE=3 > /dev/null; is "arm: key=value, any case" "$(field 0) $(field 1) $(field 2) $(field 3)" "87 0 30 3"
arm beat=2 > /dev/null; is "arm: beat floor" "$(field 2)" "5"
arm beat=90 > /dev/null; is "arm: beat ceiling, the time the cache is surely warm" "$(field 2)" "53"
arm 5h=150 > /dev/null; is "arm: a mark tops out at 100" "$(field 0)" "100"
has "arm: words it doesn't know are named" "$(arm 85 bogus x=1 90 70)" "Ignored: bogus x=1 70."
has "arm: idle=off" "$(arm idle=off)" "none after other stops"
has "arm: beat=off" "$(arm beat=off)" "; no heartbeats."
has "arm: stop" "$(arm stop)" "quotabeat is off for this session"
[[ -e $T/quotabeat/s1 ]]; is "arm: stop forgets the session" "$?" "1"
has "arm: no session id" "$(bash "$QB" arm)" "nothing was armed"
printf '{"type":"assistant","message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":900}}}}\n' > "$TR"
has "arm: a 5-minute cache gets no heartbeat" "$(arm)" "Heartbeat off: this session's prompt cache lasts 5 minutes"
is "arm: 5-minute cache state" "$(field 2)" "0"

# --- the mark notice (PostToolUse)

setup
sl 50 $((NOW + 3600)) 50 $((NOW + 86400)) > /dev/null
arm > /dev/null
post; is "below the marks: nothing" "$CODE:$OUT" "0:"
set_field 4 0; post; is "a tool marks a real turn" "$(field 4)" "1"
sl 88 $((NOW + 3600)) > /dev/null
post; is "at the 5-hour mark: exit 2" "$CODE" "2"
has "at the 5-hour mark: the notice" "$OUT" "The 5-hour usage is 88%, at its 87% mark"
has "at the 5-hour mark: what to do" "$OUT" "and end the turn without waiting yourself: the session wakes by itself at $(date -d @$((NOW + 3601)) +%H:%M), after the reset."
post; is "the notice comes once" "$CODE:$OUT" "0:"
sl 94 $((NOW + 3600)) > /dev/null
post; has "past the middle of the reserve: again, firmer" "$OUT" "well past its 87% mark: end the turn now"
sl 97 $((NOW + 3600)) 97 $((NOW + 86400)) > /dev/null
post; has "the weekly mark" "$OUT" "The weekly usage is 97%, at its 97% mark"
OUT=$(input PostToolUse ',"tool_name":"mcp__ccd_session_mgmt__get_usage","tool_response":{}' | bash "$QB" hook 2>&1)
is "the usage tool's call is left to its own hook" "$?:$OUT" "0:"
arm stop > /dev/null; sl 99 $((NOW + 3600)) > /dev/null
post; is "disarmed: nothing" "$CODE:$OUT" "0:"
setup
arm > /dev/null
post; is "no reading, just armed: nothing yet" "$CODE:$OUT" "0:"
sleep 2.2
post; has "no reading after two minutes: said once" "$OUT" "the statusLine isn't quotabeat's"
post; is "and only once" "$CODE:$OUT" "0:"

# --- the desktop app: get_usage

setup
export CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_ACCOUNT_UUID=acct-d
has "desktop arm without a reading" "$(arm)" "call mcp__ccd_session_mgmt__get_usage once now"
is "desktop arm: that request counts as asked" "$(field 11)" "$(field 10)"
set_field 11 0
post; has "desktop: a usage check is asked for" "$OUT" "Usage check due: call mcp__ccd_session_mgmt__get_usage"
post; is "desktop: asked once until it is due again" "$CODE:$OUT" "0:"
REPORT='{\n  \"plan\": {\n    \"status\": \"ok\",\n    \"windows\": [\n      {\n        \"label\": \"5-hour limit\",\n        \"percentUsed\": 16,\n        \"resetsAt\": \"2030-01-01T04:19:59.929Z\",\n        \"resetsIn\": \"4h\"\n      },\n      {\n        \"label\": \"Weekly · all models\",\n        \"percentUsed\": 2,\n        \"resetsAt\": \"2030-01-02T06:59:59.929Z\"\n      }\n    ]\n  }\n}'
USAGE_IN=$(input PostToolUse ",\"tool_name\":\"mcp__ccd_session_mgmt__get_usage\",\"tool_input\":{},\"tool_response\":[{\"type\":\"text\",\"text\":\"$REPORT\"}]")
OUT=$(printf '%s' "$USAGE_IN" | bash "$QB" usage)
is "desktop: the report is recorded" "$(cut -d' ' -f2- "$T/quotabeat/usage-acct-d")" "five_hour:16:1893471599 seven_day:2:1893567599"
has "desktop: and handed back in one line" "$OUT" '"updatedToolOutput":"Usage (recorded by quotabeat): 5h 16% ('
arm > /dev/null
OUT=$(printf '%s' "$USAGE_IN" | bash "$QB" usage)
is "desktop: a call quotabeat didn't ask for keeps its whole report" "$OUT" ""
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_ACCOUNT_UUID

# --- Stop: heartbeats after a stop, counted by the time since it

setup
sl 10 $((NOW + 3600)) > /dev/null
arm beat=3 idle=2 > /dev/null
stop_bg; wait $PID; CODE=$?
is "after a stop: a heartbeat one interval later" "$CODE:$(cat "$T/stop.err")" "2:$BEAT_NOTE"
is "the stop is where the count starts; the timer marks its heartbeat" "$(field 4):$(( $(field 5) >= NOW ))" "-1:1"
prompt
is "the heartbeat's own wake-up, handed over as a prompt (the desktop app), is no real turn" "$(field 4)" "0"
stop_bg; wait $PID; CODE=$?
is "the heartbeat's own turn: the next, due two intervals after the stop" "$CODE:$(cat "$T/stop.err")" "2:$BEAT_NOTE"
stop_bg; wait $PID; CODE=$?
is "idle=2: then the cache is let go (also with no prompt for the wake-up)" "$CODE:$(field 6):$(field 4)" "0:0:0"
post; is "a tool marks a real turn" "$(field 4)" "1"
stop_bg; wait $PID; CODE=$?
is "after a real turn they count from its stop again" "$CODE" "2"
set_field 4 0; prompt; is "a prompt marks a real turn too" "$(field 4)" "1"
arm beat=3 idle=0 > /dev/null
stop_bg; wait $PID; CODE=$?
is "idle=0: no heartbeat after a stop" "$CODE:$(field 6):$(cat "$T/stop.err")" "0:0:"
arm beat=1 > /dev/null
stop_bg; waiter; kill -STOP $PID; sleep 4; kill -CONT $PID; wait $PID; CODE=$?
is "the machine slept a little: the heartbeat goes out late" "$CODE:$(cat "$T/stop.err")" "2:$BEAT_NOTE"
arm beat=1 > /dev/null
stop_bg; waiter; kill -STOP $PID; sleep 57; kill -CONT $PID; wait $PID; CODE=$?
is "the machine slept past the time the cache is surely warm: no heartbeat" "$CODE:$(cat "$T/stop.err")" "0:"

# --- Stop: a pause at a mark

setup
sl 88 $((NOW + 8)) > /dev/null
arm beat=1 > /dev/null
post
stop_bg; wait $PID; CODE=$?
is "told to stop at a mark: wakes after the reset, no heartbeat while the cache outlasts the pause" "$CODE:$(cat "$T/stop.err")" "2:$RESET_NOTE"
is "after the wake-up nothing is pending, and that turn is a real one" "$(field 7):$(field 4)" "0:1"

setup
sl 88 $((NOW + 65)) > /dev/null
arm beat=1 > /dev/null
post
stop_bg; wait $PID; CODE=$?
is "a pause the cache can't outlast, cheap enough to bridge: heartbeats" "$CODE:$(cat "$T/stop.err")" "2:$BEAT_NOTE"
is "and the session stays paused" "$(field 7)" "$((NOW + 66))"
has "the status line says so" "$(sl 88 $((NOW + 65)))" "| paused to $(date -d @$((NOW + 66)) +%H:%M)"

setup
sl 88 $((NOW + 200)) > /dev/null
arm beat=5 > /dev/null
post
stop_bg; waiter
is "a pause whose heartbeats would cost more than a cold cache: it waits for the wake-up" "$(field 7)" "$((NOW + 201))"
sleep 7; kill -0 $PID 2> /dev/null; is "and sends no heartbeat at all" "$?:$(cat "$T/stop.err")" "0:"
kill $PID 2> /dev/null; wait $PID 2> /dev/null

setup
sl 88 $((NOW + 3600)) > /dev/null
arm beat=1 > /dev/null
stop_bg; wait $PID; CODE=$?
is "at a mark but never told (an idle session): heartbeats as after any stop, no wake-up" "$CODE:$(cat "$T/stop.err"):$(field 7)" "2:$BEAT_NOTE:0"

# --- a waiting timer gives way

setup
sl 10 $((NOW + 3600)) > /dev/null
arm beat=4 > /dev/null  # (long enough for a newer Stop to settle and take over before this one's heartbeat)
for change in newer prompt off end; do
  stop_bg; waiter || is "$change: the timer waits" no yes
  case $change in
    newer) input Stop ',"last_assistant_message":"x"' | bash "$QB" hook 2> /dev/null & NEWER=$! ;;
    prompt) prompt ;;
    off) arm stop > /dev/null ;;
    end) input SessionEnd ',"reason":"clear"' | bash "$QB" hook ;;
  esac
  wait $PID; CODE=$?
  is "$change: the waiting timer gives way quietly" "$CODE:$(cat "$T/stop.err")" "0:"
  [[ $change == newer ]] && { kill $NEWER 2> /dev/null; wait $NEWER 2> /dev/null; }
  [[ $change == end ]] && { [[ -e $T/quotabeat/s1 ]]; is "SessionEnd forgets the session" "$?" "1"; }
  [[ $change == off || $change == end ]] && arm beat=4 > /dev/null
done
stop_bg; waiter; sleep 1.1; post
wait $PID; is "a tool call alone leaves the timer be (the turn's own last PostToolUse may land late)" "$?" "2"

rm -rf "$T"
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
