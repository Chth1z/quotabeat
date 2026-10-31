#!/usr/bin/env bash
# quotabeat's tests. Each runs quotabeat.sh as Claude Code does (JSON on stdin; exit code, stdout and stderr read
# back) against a config folder of its own; QUOTABEAT_UNIT=1 makes a minute last one second.
#
#   bash tests/run.sh

cd "$(dirname "$0")/.." || exit 1
QB=$PWD/quotabeat.sh
PASS=0 FAIL=0

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
state() { cat "$T/quotabeat/s1"; }
field() { local f; read -ra f < "$T/quotabeat/s1"; echo "${f[$1]}"; }  # 0 on, 1 m5, 2 m7, 3 beat, 4 beats, 5 gen, 7 desk, 8 noticed, 9 asked, 10 wake
stop_bg() { input Stop ",\"stop_hook_active\":false,\"last_assistant_message\":\"${1:-done}\",\"background_tasks\":[]" | bash "$QB" hook 2> "$T/stop.err" & PID=$!; }
waiter() { for _ in $(seq 1 80); do [[ $(field 5) == "$PID" ]] && return 0; sleep 0.1; done; return 1; }  # this Stop waits

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
has "arm: defaults" "$(arm)" "stop at 87% of the 5-hour window, 97% of the weekly; heartbeat after 50 idle minutes. Usage now: 5h 6%"
is "arm: state" "$(state)" "1 87 97 50 0 0 acct-t 0 - 0 0 $(field 11)"
arm 80 90 > /dev/null; is "arm: two numbers" "$(field 1) $(field 2)" "80 90"
arm week=off > /dev/null; is "arm: week=off" "$(field 1) $(field 2)" "87 0"
arm 5h 70 beat=30 > /dev/null; is "arm: label value, beat=" "$(field 1) $(field 2) $(field 3)" "70 97 30"
arm beat=2 > /dev/null; is "arm: beat floor" "$(field 3)" "5"
arm 95% Beat=OFF > /dev/null; is "arm: percent sign, any case" "$(field 1) $(field 3)" "95 0"
has "arm: stop" "$(arm stop)" "off for this session"
is "arm: stop state" "$(field 0)" "0"
unset CLAUDE_CODE_SESSION_ID
has "arm: no session id" "$(bash "$QB" arm)" "nothing was armed"
printf '{"type":"assistant","message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":900}}}}\n' > "$TR"
has "arm: a 5-minute cache gets no heartbeat" "$(arm)" "Heartbeat off: this session's prompt cache lasts 5 minutes"
is "arm: 5-minute cache state" "$(field 3)" "0"

# --- the mark notice (PostToolUse)

setup
sl 50 $((NOW + 3600)) 50 $((NOW + 86400)) > /dev/null
arm > /dev/null
post; is "below the marks: nothing" "$CODE:$OUT" "0:"
[[ -f $T/quotabeat/s1.act ]]; is "a tool marks the session active" "$?" "0"
sl 88 $((NOW + 3600)) > /dev/null
post; is "at the 5-hour mark: exit 2" "$CODE" "2"
has "at the 5-hour mark: the notice" "$OUT" "The 5-hour usage is 88%, at its 87% mark"
has "at the 5-hour mark: what to do" "$OUT" "end the turn; don't wait or sleep yourself: the session wakes by itself at"
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
is "desktop arm: that request counts as asked" "$(field 9)" "$(field 11)"
sed -i 's/^\(\([^ ]* \)\{9\}\)[0-9]*/\10/' "$T/quotabeat/s1"
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

# --- Stop: heartbeats, the pause, the wake-up

setup
sl 10 $((NOW + 3600)) > /dev/null
arm beat=1 > /dev/null
stop_bg; wait $PID; CODE=$?
is "idle: a heartbeat after a minute" "$CODE" "2"
has "idle: the heartbeat's words" "$(cat "$T/stop.err")" "Idle heartbeat to keep the prompt cache warm. Reply with exactly . and nothing else."
stop_bg .; waiter; is "a heartbeat's own turn counts" "$(field 4)" "1"
kill $PID 2> /dev/null; wait $PID 2> /dev/null
sed -i 's/^\(1 [0-9]* [0-9]* [0-9]* \)[0-9]*/\118/' "$T/quotabeat/s1"
stop_bg .; wait $PID; CODE=$?
is "after 19 heartbeats in a row the cache is let go" "$CODE:$(field 4):$(field 5)" "0:19:0"
stop_bg 'real work'; waiter; is "a real turn starts the count again" "$(field 4)" "0"
kill $PID 2> /dev/null; wait $PID 2> /dev/null

setup
sl 88 $((NOW + 6)) > /dev/null
arm beat=off > /dev/null
stop_bg; wait $PID; CODE=$?
is "at a mark: wakes after the reset" "$CODE" "2"
has "at a mark: the wake-up's words" "$(cat "$T/stop.err")" "The 5-hour window has reset. Go on with the work where it stopped."
is "after the wake-up nothing is pending" "$(field 10)" "0"

setup
sl 88 $((NOW + 8)) > /dev/null
arm beat=1 > /dev/null
stop_bg; wait $PID; CODE=$?
is "a short pause gets heartbeats" "$CODE" "2"
has "a heartbeat during the pause" "$(cat "$T/stop.err")" "through the quota pause (it ends at"

setup
sl 88 $((NOW + 100)) > /dev/null
arm beat=1 > /dev/null
stop_bg; waiter
is "a pause longer than 19 heartbeats: none, just the wake-up" "$(field 10)" "$((NOW + 101))"
kill $PID 2> /dev/null; wait $PID 2> /dev/null

setup
sl 10 $((NOW + 3600)) > /dev/null
arm beat=4 > /dev/null  # (long enough for a newer Stop to settle and take over before this one's beat)
for change in newer active prompt off end; do
  stop_bg; waiter || is "$change: the Stop hook waits" no yes
  case $change in
    newer) input Stop ',"last_assistant_message":"x"' | bash "$QB" hook 2> /dev/null & NEWER=$! ;;
    active) sleep 1.1; post ;;
    prompt) sleep 1.1; input UserPromptSubmit ',"prompt":"hi"' | bash "$QB" hook ;;
    off) arm stop > /dev/null ;;
    end) input SessionEnd ',"reason":"clear"' | bash "$QB" hook ;;
  esac
  wait $PID; CODE=$?
  is "$change: the waiting Stop gives way quietly" "$CODE:$(cat "$T/stop.err")" "0:"
  [[ $change == newer ]] && { kill $NEWER 2> /dev/null; wait $NEWER 2> /dev/null; }
  [[ $change == end ]] && { [[ -e $T/quotabeat/s1 ]]; is "SessionEnd forgets the session" "$?" "1"; }
  [[ $change == off || $change == end ]] && arm beat=4 > /dev/null
done

# --- install.sh

setup
S=$T/settings.json
bash install.sh > /dev/null
OURS="{\"type\": \"command\", \"command\": \"bash \\\"$(command -v cygpath > /dev/null && cygpath -m "$T" || echo "$T")/skills/quotabeat/quotabeat.sh\\\" statusline\"}"
is "install: no settings.json" "$(cat "$S")" "{
  \"statusLine\": $OURS
}"
[[ -f $T/skills/quotabeat/SKILL.md && -f $T/skills/quotabeat/quotabeat.sh ]]; is "install: the skill is copied" "$?" "0"
printf '{\n  "theme": "dark",\n  "env": {\n    "A": "1"\n  }\n}' > "$S"
bash install.sh > /dev/null
is "install: added to settings that have none" "$(cat "$S")" "{
  \"statusLine\": $OURS,
  \"theme\": \"dark\",
  \"env\": {
    \"A\": \"1\"
  }
}"
bash install.sh uninstall > /dev/null
is "uninstall: the entry goes with its comma" "$(cat "$S")" $'{\n  \n  "theme": "dark",\n  "env": {\n    "A": "1"\n  }\n}'
THEIRS='{"type": "command", "command": "jq -r \"[\\(.model.display_name)] & \\(.cwd)\""}'
printf '{\n  "theme": "dark",\n  "statusLine": %s\n}' "$THEIRS" > "$S"
bash install.sh 2> /dev/null; is "install: someone else's status line stays" "$?:$(cat "$S")" "1:$(printf '{\n  "theme": "dark",\n  "statusLine": %s\n}' "$THEIRS")"
bash install.sh --replace > /dev/null
is "install --replace" "$(cat "$S")" "$(printf '{\n  "theme": "dark",\n  "statusLine": %s\n}' "$OURS")"
bash install.sh > /dev/null; is "install again: its own line is no obstacle" "$?" "0"
bash install.sh uninstall > /dev/null
is "uninstall: the line set before comes back, & and \\ intact" "$(cat "$S")" "$(printf '{\n  "theme": "dark",\n  "statusLine": %s\n}' "$THEIRS")"
[[ -e $T/quotabeat/statusline-before.json ]]; is "uninstall: nothing kept" "$?" "1"

rm -rf "$T"
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
