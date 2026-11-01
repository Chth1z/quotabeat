#!/usr/bin/env bash
# quotabeat's tests. Each runs quotabeat.sh as Claude Code does (JSON on stdin; exit code, stdout and stderr read
# back) against a config folder of its own, with debug logs written the way Claude Code writes them; QUOTABEAT_UNIT=1
# makes a minute last one second.
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
  unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ORGANIZATION_UUID ANTHROPIC_LOG DEBUG DEBUG_SDK DEBUG_CLAUDE_AGENT_SDK
  mkdir -p "$T/projects/p" "$T/debug"
  TR=$T/projects/p/s1.jsonl
  : > "$TR"
  NOW=$(date +%s)
}
cli_log() {  # cli_log <5h utilization> <5h reset> [<7d utilization> <7d reset>]: a response of terminal session s1, as
             # its debug log keeps it: one line, \n escapes, single quotes
  local n='\n' h="    'anthropic-ratelimit-unified-5h-reset': '$2',${n}    'anthropic-ratelimit-unified-5h-utilization': '$1',${n}"
  [[ -n ${3:-} ]] && h+="    'anthropic-ratelimit-unified-7d-reset': '$4',${n}    'anthropic-ratelimit-unified-7d-utilization': '$3',${n}"
  printf '%s\n' "2026-11-01T09:21:22.473Z [DEBUG] \"console.log: [log_1] response start {${n}  url: 'https://api.anthropic.com/v1/messages?beta=true',${n}  status: 200,${n}  headers: {${n}    'anthropic-organization-id': 'org-c',${n}${h}  },${n}  durationMs: 2244${n}}\"" >> "$T/debug/s1.txt"
}
desk_log() {  # desk_log <file> <org> <5h utilization> <5h reset> <7d utilization> <7d reset>: the desktop app's SDK log,
              # a line per header, some out of order the way it writes them
  local p='2026-11-01T09:29:05.324Z Non-JSON stdout:'
  printf '%s\n' "$p [log_2] response start {" "$p   url: \"https://api.anthropic.com/v1/messages?beta=true\"," \
    "$p     \"anthropic-organization-id\": \"$2\"," "$p   headers: {" \
    "$p     \"anthropic-ratelimit-unified-5h-reset\": \"$4\"," "$p     \"anthropic-ratelimit-unified-5h-utilization\": \"$3\"," \
    "$p   durationMs: 4962," "$p     \"anthropic-ratelimit-unified-7d-reset\": \"$6\"," \
    "$p     \"anthropic-ratelimit-unified-7d-utilization\": \"$5\"," "$p   }," "$p }" >> "$T/debug/$1"
}
arm() { CLAUDE_CODE_SESSION_ID=s1 bash "$QB" arm "$@"; }
input() { printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","hook_event_name":"%s"%s}' "$TR" "$T" "$1" "${2:-}"; }
post() {  # a tool ran: the async PostToolUse hook's stderr and exit code
  OUT=$(input PostToolUse ',"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}' | bash "$QB" hook 2>&1)
  CODE=$?
}
prompt() { input UserPromptSubmit ',"prompt":"hi"' | bash "$QB" hook; }
state() { cat "$T/quotabeat/s1"; }
# 0 m5, 1 m7, 2 beat, 3 idle, 4 active, 5 since, 6 gen, 7 wake, 8 armed, 9 noticed
field() { local f; read -ra f < "$T/quotabeat/s1"; echo "${f[$1]}"; }
set_field() { local f; read -ra f < "$T/quotabeat/s1"; f[$1]=$2; echo "${f[*]}" > "$T/quotabeat/s1"; }
stop_bg() {  # the turn ends: its Stop hook runs in the background
  input Stop ',"stop_hook_active":false,"last_assistant_message":"done","background_tasks":[],"session_crons":[]' |
    bash "$QB" hook 2> "$T/stop.err" &
  PID=$!
}
waiter() { for _ in $(seq 1 80); do [[ $(field 6) == "$PID" ]] && return 0; sleep 0.1; done; return 1; }  # its timer waits
hm() { date -d "@$1" +%H:%M; }

# --- the usage, from Claude Code's debug log

setup
has "no debug log: no reading" "$(arm)" "No usage reading yet: Claude Code's debug log has no rate-limit headers for this session"
has "env set, before the first response: says so without blaming the env" "$(ANTHROPIC_LOG=debug DEBUG_SDK=1 arm)" "No usage reading yet: waiting for this session's first response"
cli_log 0.235 $((NOW + 3600)) 0.41 $((NOW + 3 * 86400))
has "a terminal session's own log" "$(arm)" "Usage now: 5h 23% ($(hm $((NOW + 3600)))), 7d 41% ($(LC_ALL=C date -d @$((NOW + 3 * 86400)) '+%a %H:%M'))."
cli_log 0.875 $((NOW + 3600)) 0.42 $((NOW + 3 * 86400))
has "the newest response counts; the percent is rounded down" "$(arm)" "Usage now: 5h 87% ("
cli_log 1 $((NOW + 3600))
has "a window a response doesn't name keeps its last value" "$(arm)" "5h 100% ($(hm $((NOW + 3600)))), 7d 42% ("
printf '%s\n' "'anthropic-ratelimit-unified-5h-utilization': '0.5', 'anthropic-ratelimit-unified-5h-reset': '$((NOW + 3600))'" > "$T/debug/s2.txt"
has "another terminal session's log is not this one's" "$(arm)" "5h 100% ("
setup
export CLAUDE_CODE_ORGANIZATION_UUID=org-d
desk_log sdk-a.txt org-d 0.35 $((NOW + 3600)) 0.3 $((NOW + 86400))
has "the desktop app's log, its lines out of order" "$(arm)" "Usage now: 5h 35% ($(hm $((NOW + 3600)))), 7d 30% ($(LC_ALL=C date -d @$((NOW + 86400)) '+%a %H:%M'))."
sleep 0.2
desk_log sdk-b.txt org-x 0.9 $((NOW + 3600)) 0.9 $((NOW + 86400))
has "a newer log of another organization doesn't count" "$(arm)" "Usage now: 5h 35% ("
desk_log sdk-a.txt org-x 0.9 $((NOW + 3600)) 0.9 $((NOW + 86400))
has "a response of another organization in the same desktop log doesn't count" "$(arm)" "Usage now: 5h 35% ("
unset CLAUDE_CODE_ORGANIZATION_UUID
has "without this session's organization the desktop logs aren't read" "$(arm)" "No usage reading yet"

# --- arming

setup
cli_log 0.06 $((NOW + 3600)) 0.94 $((NOW + 86400))
has "arm: defaults" "$(arm)" "quotabeat on: stop at 87% of the 5-hour window and 97% of the weekly; a heartbeat every 47 minutes while the session waits: 7 after a stop, all the way through a quota pause when that costs less than a cold cache. Usage now: 5h 6%"
is "arm: state" "$(state)" "87 97 47 7 1 0 0 0 $(field 8) -"
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
cli_log 0.5 $((NOW + 3600)) 0.5 $((NOW + 86400))
arm > /dev/null
post; is "below the marks: nothing" "$CODE:$OUT" "0:"
set_field 4 0; post; is "a tool marks a real turn" "$(field 4)" "1"
cli_log 0.869 $((NOW + 3600)) 0.5 $((NOW + 86400))
post; is "86.9% is not yet at an 87% mark" "$CODE:$OUT" "0:"
cli_log 0.88 $((NOW + 300)) 0.5 $((NOW + 86400))
post; is "at the 5-hour mark: exit 2" "$CODE" "2"
has "at the 5-hour mark: the notice" "$OUT" "The 5-hour usage is 88%, at its 87% mark."
has "at the 5-hour mark: what to do" "$OUT" "and end the turn without waiting yourself: the session wakes by itself at $(hm $((NOW + 301))), after the reset."
[[ $OUT == *"No heartbeats"* ]]; is "a pause cheap enough to bridge doesn't warn that heartbeats are skipped" "$?" "1"
post; is "the notice comes once" "$CODE:$OUT" "0:"
cli_log 0.94 $((NOW + 300)) 0.5 $((NOW + 86400))
post; has "past the middle of the reserve: again, firmer" "$OUT" "well past its 87% mark: end the turn now"
printf '{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":780,"cache_read_input_tokens":510000,"output_tokens":90}}}\n' > "$TR"
cli_log 0.97 $((NOW + 300)) 0.97 $((NOW + 86400))
post; has "the weekly mark" "$OUT" "The weekly usage is 97%, at its 97% mark"
has "when heartbeats through the pause would cost more than a cold cache: tells the user context size and asks about /compact" "$OUT" "No heartbeats will run during this wait ("
has "includes the rounded context token size from the transcript" "$OUT" "that the context is at ~511k tokens and ask whether they want to /compact."
arm stop > /dev/null; cli_log 0.99 $((NOW + 3600))
post; is "disarmed: nothing" "$CODE:$OUT" "0:"
setup
arm > /dev/null
post; is "no reading, just armed: nothing yet" "$CODE:$OUT" "0:"
sleep 2.2
post; has "no reading after two minutes: said once" "$OUT" "No usage reading: Claude Code's debug log has no rate-limit headers"
post; is "and only once" "$CODE:$OUT" "0:"

# --- Stop: heartbeats after a stop, counted by the time since it

setup
cli_log 0.1 $((NOW + 3600))
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
cli_log 0.88 $((NOW + 8))
arm beat=1 > /dev/null
post
stop_bg; wait $PID; CODE=$?
is "told to stop at a mark: wakes after the reset, no heartbeat while the cache outlasts the pause" "$CODE:$(cat "$T/stop.err")" "2:$RESET_NOTE"
is "after the wake-up nothing is pending, and that turn is a real one" "$(field 7):$(field 4)" "0:1"

setup
cli_log 0.88 $((NOW + 65))
arm beat=1 > /dev/null
post
stop_bg; wait $PID; CODE=$?
is "a pause the cache can't outlast, cheap enough to bridge: heartbeats" "$CODE:$(cat "$T/stop.err")" "2:$BEAT_NOTE"
is "and the session stays paused" "$(field 7)" "$((NOW + 66))"

setup
cli_log 0.88 $((NOW + 200))
arm beat=5 > /dev/null
post
stop_bg; waiter
is "a pause whose heartbeats would cost more than a cold cache: it waits for the wake-up" "$(field 7)" "$((NOW + 201))"
sleep 7; kill -0 $PID 2> /dev/null; is "and sends no heartbeat at all" "$?:$(cat "$T/stop.err")" "0:"
kill $PID 2> /dev/null; wait $PID 2> /dev/null

setup
cli_log 0.88 $((NOW + 3600))
arm beat=1 > /dev/null
stop_bg; wait $PID; CODE=$?
is "at a mark but never told (an idle session): heartbeats as after any stop, no wake-up" "$CODE:$(cat "$T/stop.err"):$(field 7)" "2:$BEAT_NOTE:0"

# --- a waiting timer gives way

setup
cli_log 0.1 $((NOW + 3600))
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
stop_bg; sleep 0.4; prompt
wait $PID; is "a prompt while Stop settles (before the timer starts) makes it give way and keeps the turn active" "$?:$(field 4)" "0:1"

rm -rf "$T"
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
