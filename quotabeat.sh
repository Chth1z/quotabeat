#!/usr/bin/env bash
# quotabeat: keeps unattended Claude Code work inside the plan's usage limits, and its prompt cache warm, without
# asking any server. One script, by role:
#
#   statusline  the statusLine command. Every response tells Claude Code the account's 5-hour and weekly usage
#               (rate_limits); this keeps it in <config>/quotabeat/usage-<account> and prints the status line.
#   arm [args]  runs when /quotabeat is invoked (the !`...` line of SKILL.md): this session's marks and heartbeat.
#   hook        the skill's hooks, by event:
#                 PostToolUse (async)  once a window reaches its mark, tells Claude to wrap up and end the turn;
#                                      in the desktop app, which runs no status line, asks for a usage check
#                 Stop (async)         at a mark: waits for the reset, then wakes the session to go on; idle:
#                                      heartbeats that keep the prompt cache warm, at most 19 in a row (by then
#                                      they have cost about one cold re-read, and a cold re-read is cheaper)
#                 UserPromptSubmit     marks the session active; SessionEnd forgets it
#   usage       PostToolUse of the desktop app's get_usage tool: records what it returned and hands Claude one
#               line in place of the whole report.
#
# Bash and coreutils only (Git Bash on Windows). QUOTABEAT_UNIT is the seconds in a minute (tests shorten it); a
# file <config>/quotabeat/debug makes the hooks append their input to debug.log there.

LC_ALL=C
shopt -u patsub_replacement 2> /dev/null  # (bash 5.2+: else & and \ in a ${x/a/b} replacement change meaning)
U=${QUOTABEAT_UNIT:-60}
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG=${CFG//\\//}
DIR=$CFG/quotabeat
MAXBEATS=19
USAGE_TOOL=mcp__ccd_session_mgmt__get_usage

now() { printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s); }

clock() {  # CLOCK: the epoch $1 as people read it, 04:00 within half a day, Mon 09:00 further off
  local f='%H:%M'
  (( $1 - NOW >= 43200 )) && f='%a %H:%M'
  printf -v CLOCK "%($f)T" "$1" 2>/dev/null || CLOCK=$(date -d "@$1" +"$f" 2>/dev/null || date -r "$1" +"$f")
}

account() {  # ACCT: the desktop app and the SDK name it in the environment; a terminal's login is in .claude.json
  ACCT=${CLAUDE_CODE_ACCOUNT_UUID:-}
  local f=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json j=
  f=${f//\\//}
  if [[ -z $ACCT && -r $f ]]; then
    IFS= read -r -d '' j < "$f"
    [[ $j =~ \"oauthAccount\"[[:space:]]*:[[:space:]]*\{[^}]*\"accountUuid\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] &&
      ACCT=${BASH_REMATCH[1]}
  fi
  ACCT=${ACCT:-default}
}

# --- readings: one line per account, "<when> <window>:<percent>:<reset> ...", e.g. 1793464078 five_hour:6:1793476800

load_usage() {
  TAKEN=0 WIN=()
  local f=()
  [[ -r $DIR/usage-$ACCT ]] && read -ra f < "$DIR/usage-$ACCT" && TAKEN=${f[0]:-0} WIN=("${f[@]:1}")
}

record() {  # NEW (window:percent:reset ...) into this account's reading: within one window the larger stands, so an
            # idle session's line, run again on old data, can't lower it; a later window replaces an earlier one
  load_usage
  local out=() w o n r or o_pct w_pct
  for o in "${WIN[@]}"; do
    [[ " ${NEW[*]} " == *" ${o%%:*}:"* ]] || out+=("$o")
  done
  for w in "${NEW[@]}"; do
    n=${w%%:*} r=${w##*:}
    for o in "${WIN[@]}"; do
      [[ ${o%%:*} == "$n" ]] || continue
      or=${o##*:} o_pct=${o#*:} o_pct=${o_pct%%:*} w_pct=${w#*:} w_pct=${w_pct%%:*}
      if (( r - or < 600 && or - r < 600 )); then
        (( ${o_pct%.*} > ${w_pct%.*} )) && w=$o
      elif (( or > r )); then
        w=$o
      fi
    done
    out+=("$w")
  done
  [[ -d $DIR ]] || mkdir -p "$DIR"
  printf '%s %s\n' "$NOW" "${out[*]}" > "$DIR/usage-$ACCT.$$" && mv -f "$DIR/usage-$ACCT.$$" "$DIR/usage-$ACCT"
  TAKEN=$NOW WIN=("${out[@]}")
}

over() {  # HITS (window:percent:mark:reset:level ...): windows at or past their mark that haven't reset; level 2
          # once past the middle of the reserve above the mark
  HITS=()
  local w n p r m
  for w in "${WIN[@]}"; do
    n=${w%%:*} r=${w##*:} p=${w#*:} p=${p%%:*} p=${p%.*}
    case $n in five_hour) m=$M5 ;; seven_day*) m=$M7 ;; *) continue ;; esac
    (( m > 0 && r > NOW && p >= m )) || continue
    HITS+=("$n:$p:$m:$r:$(( p >= (m + 100) / 2 ? 2 : 1 ))")
  done
}

name() {  # NAME: what people call a window
  case $1 in five_hour) NAME=5-hour ;; seven_day) NAME=weekly ;; seven_day_*) NAME="weekly ${1#seven_day_}" ;; *) NAME=$1 ;; esac
}

describe() {  # DESC: "5h 6% (04:00), 7d 94% (Mon 09:00)", from WIN, the 5-hour window first
  DESC=
  local w n p r in_order=()
  for w in "${WIN[@]}"; do
    if [[ $w == five_hour:* ]]; then in_order=("$w" "${in_order[@]}"); else in_order+=("$w"); fi
  done
  for w in "${in_order[@]}"; do
    n=${w%%:*} r=${w##*:} p=${w#*:} p=${p%%:*} p=${p%.*}
    case $n in five_hour) n=5h ;; seven_day) n=7d ;; seven_day_*) n="7d ${n#seven_day_}" ;; esac
    if (( r > NOW )); then clock "$r"; DESC+="${DESC:+, }$n $p% ($CLOCK)"; else DESC+="${DESC:+, }$n 0%"; fi
  done
}

# --- a session's state, one line: on m5 m7 beat beats gen acct desk noticed asked wake armed

load_state() {
  S=$DIR/$SID
  [[ -r $S ]] && read -r ON M5 M7 BEAT BEATS GEN ACCT DESK NOTICED ASKED WAKE ARMED < "$S"
}

save_state() {
  [[ -d $DIR ]] || mkdir -p "$DIR"
  printf '%s %s %s %s %s %s %s %s %s %s %s %s\n' "$ON" "$M5" "$M7" "$BEAT" "$BEATS" "$GEN" "$ACCT" "$DESK" \
    "$NOTICED" "$ASKED" "$WAKE" "$ARMED" > "$S.$$" && mv -f "$S.$$" "$S"
}

prune() {  # NOTICED forgets the windows that have reset
  local e r out=-
  for e in ${NOTICED//,/ }; do
    [[ $e == - ]] && continue
    r=${e#*@} r=${r%%:*}
    [[ $e == *@* ]] && (( r <= NOW )) && continue
    out+=",$e"
  done
  NOTICED=$out
}

# --- arm: /quotabeat [5h mark] [weekly mark] [5h=N] [week=N] [beat=minutes] [off] [stop]

arm() {
  SID=${CLAUDE_CODE_SESSION_ID:-}
  if [[ -z $SID ]]; then
    echo "quotabeat: this environment gives no session id (CLAUDE_CODE_SESSION_ID), so nothing was armed."
    return 0
  fi
  S=$DIR/$SID
  now
  account
  ON=1 M5=87 M7=97 BEAT=50 BEATS=0 GEN=0 DESK=0 NOTICED=- ASKED=0 WAKE=0 ARMED=$NOW
  [[ ${CLAUDE_CODE_ENTRYPOINT:-} == claude-desktop ]] && DESK=1
  local t label= pos=0 v
  shopt -s nocasematch
  for t in "$@"; do
    case $t in *=*|*:*) label=${t%%[=:]*} t=${t#*[=:]} ;; esac
    case $label in 5h|hour|five_hour) label=5h ;; week|weekly|w|7d|seven_day) label=week ;; beat|heartbeat) label=beat ;; esac
    case $t in
      5h|hour|five_hour) label=5h; continue ;;
      week|weekly|w|7d|seven_day) label=week; continue ;;
      beat|heartbeat) label=beat; continue ;;
      stop|disarm) ON=0; continue ;;
      off) [[ -z $label ]] && { ON=0; continue; }; v=0 ;;
      ''|*[!0-9.%]*) label=; continue ;;
      *) v=${t%%[.%]*} v=$(( 10#${v:-0} )) ;;
    esac
    if [[ -z $label ]]; then
      (( pos++ == 0 )) && label=5h || label=week
    fi
    case $label in 5h) M5=$v ;; week) M7=$v ;; beat) BEAT=$v ;; esac
    label=
  done
  shopt -u nocasematch
  if [[ $ON != 1 ]]; then
    load_state
    ON=0 GEN=0 WAKE=0
    save_state
    echo "quotabeat is off for this session: no stop at a mark, no heartbeat."
    return 0
  fi
  (( M5 > 100 )) && M5=100
  (( M7 > 100 )) && M7=100
  (( BEAT > 0 && BEAT < 5 )) && BEAT=5
  (( BEAT > 55 )) && BEAT=55   # past 55 minutes the 1-hour cache can lapse before a heartbeat lands
  local note= f g
  # A session whose prompt cache lives 5 minutes gains nothing from a heartbeat every 50.
  for f in "$CFG"/projects/*/"$SID".jsonl; do
    [[ -r $f ]] || continue
    g=$(tail -c 400000 "$f" | grep -o '"cache_creation":{[^}]*}' | tail -n 1)
    if [[ $g =~ \"ephemeral_5m_input_tokens\":[1-9] && ! $g =~ \"ephemeral_1h_input_tokens\":[1-9] ]]; then
      BEAT=0 note=" Heartbeat off: this session's prompt cache lasts 5 minutes, a heartbeat can't keep it."
    fi
  done
  load_usage
  (( DESK && ! TAKEN )) && ASKED=$NOW  # the line below asks for a check: its report gets shortened too
  save_state
  local marks="${M5}% of the 5-hour window, ${M7}% of the weekly"
  (( M5 == 0 )) && marks="${M7}% of the weekly window (5-hour off)"
  (( M7 == 0 )) && marks="${M5}% of the 5-hour window (weekly off)"
  (( M5 == 0 && M7 == 0 )) && marks="no mark"
  local beat="heartbeat after $BEAT idle minutes"
  (( BEAT == 0 )) && beat="no heartbeat"
  local usage
  if (( TAKEN )); then
    describe
    usage="Usage now: $DESC."
  elif (( DESK )); then
    usage="No usage reading for this account yet (the desktop app runs no status line): call $USAGE_TOOL once now; quotabeat reads its result."
  else
    usage="No usage reading for this account yet: it comes with the next response if the statusLine is quotabeat's (see its README); until then nothing stops this session."
  fi
  echo "quotabeat on: stop at $marks; $beat. $usage$note"
}

# --- hooks

post() {  # PostToolUse, in the background: the mark notice, and in the desktop app the call for a usage check
  load_state && [[ $ON == 1 ]] || return 0
  : > "$S.act"
  [[ $IN == *"\"tool_name\":\"$USAGE_TOOL\""* ]] && return 0  # its own hook reads it
  now
  load_usage
  local msg= changed=0
  if (( DESK )); then
    local due=$(( 5 * U )) w p m head=100
    if (( TAKEN )); then  # half a minute per point left before the nearest mark, from 5 minutes to an hour
      for w in "${WIN[@]}"; do
        p=${w#*:} p=${p%%:*} p=${p%.*}
        case ${w%%:*} in five_hour) m=$M5 ;; seven_day*) m=$M7 ;; *) continue ;; esac
        (( m > 0 && ${w##*:} > NOW && m - p < head )) && head=$(( m - p ))
      done
      due=$(( head / 2 ))
      (( due < 5 )) && due=5
      (( due > 60 )) && due=60
      due=$(( due * U ))
    fi
    if (( NOW - TAKEN >= due && NOW - ASKED >= due )); then
      ASKED=$NOW changed=1
      msg="Usage check due: call $USAGE_TOOL (no arguments; load it with ToolSearch if it isn't loaded). quotabeat reads its result and shortens it."
    fi
  elif (( ! TAKEN && NOW - ARMED >= 2 * U )) && [[ $NOTICED != *,blind* ]]; then
    NOTICED+=,blind changed=1
    msg="No usage reading for this account: the statusLine isn't quotabeat's (see its README), so nothing stops this session at a mark. Tell the user in one line."
  fi
  over
  local h n p m r l key until=0
  for h in "${HITS[@]}"; do
    n=${h%%:*} h=${h#*:} p=${h%%:*} h=${h#*:} m=${h%%:*} h=${h#*:} r=${h%%:*} l=${h##*:}
    key=$n@$r:$l
    [[ ,$NOTICED, == *",$key,"* ]] && continue
    NOTICED+=,$key changed=1
    name "$n"
    clock "$r"
    (( r > until )) && until=$r
    if (( l == 1 )); then
      msg+="${msg:+ }The $NAME usage is $p%, at its $m% mark (it resets at $CLOCK)."
    else
      msg+="${msg:+ }The $NAME usage is $p%, well past its $m% mark: end the turn now."
    fi
  done
  if (( until )); then
    clock $(( until + U ))
    msg+=" Finish or checkpoint the step at hand, note what comes next, and end the turn; don't wait or sleep yourself: the session wakes by itself at $CLOCK."
  fi
  (( changed )) && { prune; save_state; }
  [[ -n $msg ]] || return 0
  printf '%s\n' "$msg" >&2
  return 2
}

stop() {  # Stop, in the background: wait at a mark for the reset, or keep the cache warm while idle
  [[ -r $DIR/$SID ]] || return 0
  sleep 2  # the turn's last reading lands a moment after Stop (the status line's 300 ms debounce), and the
           # last tool's PostToolUse is done by then
  load_state && [[ $ON == 1 ]] || return 0
  if [[ $IN == *'"last_assistant_message":"."'* ]]; then BEATS=$(( BEATS + 1 )); else BEATS=0; fi
  now
  load_usage
  over
  local h r wake=0 next=0 names=
  for h in "${HITS[@]}"; do
    r=${h#*:*:*:} r=${r%%:*}
    (( r > wake )) && wake=$r
    name "${h%%:*}"
    [[ $names == *"$NAME"* ]] || names+="${names:+ and }$NAME"
  done
  if (( wake )); then
    wake=$(( wake + U ))  # a minute after the reset
    next=$wake
    # Heartbeats through the pause only when it is short enough that they cost less than one cold re-read.
    (( BEAT > 0 && wake - NOW <= MAXBEATS * BEAT * U && NOW + BEAT * U < wake )) && next=$(( NOW + BEAT * U ))
  elif (( BEAT > 0 && BEATS < MAXBEATS )); then
    next=$(( NOW + BEAT * U ))
  fi
  WAKE=$wake GEN=0
  (( next )) && GEN=$$
  save_state
  (( next )) || return 0
  : > "$S.w"
  while now; (( NOW < next )); do sleep $(( next - NOW )); done
  load_state || return 0                       # the session ended
  [[ $ON == 1 && $GEN == "$$" ]] || return 0   # turned off, or a newer turn's Stop took over
  [[ $S.act -nt $S.w ]] && return 0            # the session went on: a tool ran, or the user wrote
  if (( next == wake )); then
    WAKE=0
    prune
    save_state
    printf 'The %s window has reset. Go on with the work where it stopped.\n' "$names" >&2
  elif (( wake )); then
    clock "$wake"
    printf 'Heartbeat to keep the prompt cache warm through the quota pause (it ends at %s). Reply with exactly . and nothing else.\n' "$CLOCK" >&2
  else
    printf 'Idle heartbeat to keep the prompt cache warm. Reply with exactly . and nothing else.\n' >&2
  fi
  return 2
}

hook() {
  IFS= read -r -d '' -n 16384 IN  # the fields used come first; a tool's output can run long
  (( ${#IN} >= 16384 )) && cat > /dev/null
  [[ $IN =~ \"session_id\":\"([^\"]+)\" ]] || return 0
  SID=${BASH_REMATCH[1]}
  [[ -f $DIR/debug ]] && printf '%s\n' "$IN" >> "$DIR/debug.log"
  [[ $IN =~ \"hook_event_name\":\"([A-Za-z]+)\" ]] || return 0
  case ${BASH_REMATCH[1]} in
    PostToolUse) post ;;
    Stop) stop ;;
    UserPromptSubmit) [[ -f $DIR/$SID ]] && : > "$DIR/$SID.act" ;;
    SessionEnd) rm -f "$DIR/$SID" "$DIR/$SID.act" "$DIR/$SID.w" ;;
  esac
}

# --- the desktop app's get_usage, read in its PostToolUse

iso_epoch() {  # EPOCH from 2026-10-31T20:19:59.929Z (UTC), by the days-from-civil arithmetic
  [[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}) ]] || return 1
  local y=$(( 10#${BASH_REMATCH[1]} )) m=$(( 10#${BASH_REMATCH[2]} )) d=$(( 10#${BASH_REMATCH[3]} ))
  (( y -= m <= 2 ))
  local era=$(( y / 400 )) yoe doy
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  EPOCH=$(( (era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468) * 86400
            + 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))
}

usage() {
  IN=$(cat)
  [[ $IN =~ \"session_id\":\"([^\"]+)\" ]] || return 0
  SID=${BASH_REMATCH[1]}
  [[ -f $DIR/debug ]] && printf '%s\n' "$IN" >> "$DIR/debug.log"
  now
  account
  # The report is JSON inside the tool's text, so its quotes may come escaped: \"label\": \"5-hour limit\", ...
  local rest=${IN//\\\"/\"} re='"label": *"([^"]*)"[^}]*"percentUsed": *([0-9.]+)[^}]*"resetsAt": *"([^"]+)"' n
  NEW=()
  while [[ $rest =~ $re ]]; do
    rest=${rest#*"${BASH_REMATCH[0]}"}
    local label=${BASH_REMATCH[1]} pct=${BASH_REMATCH[2]} at=${BASH_REMATCH[3]}
    iso_epoch "$at" || continue
    shopt -s nocasematch
    case $label in
      5-hour*|*session*) n=five_hour ;;
      weekly*all*) n=seven_day ;;
      weekly*opus*) n=seven_day_opus ;;
      weekly*sonnet*) n=seven_day_sonnet ;;
      weekly*) n=seven_day_other ;;
      *) n= ;;
    esac
    shopt -u nocasematch
    [[ -n $n ]] && NEW+=("$n:${pct%.*}:$EPOCH")
  done
  (( ${#NEW[@]} )) || return 0
  record
  load_state || return 0
  # Shorten the report only when quotabeat asked for it: a call of Claude's own wants the whole of it.
  (( ASKED && NOW - ASKED < 15 * U )) || return 0
  describe
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"Usage (recorded by quotabeat): %s."}}\n' "$DESC"
}

# --- the status line

statusline() {
  IFS= read -r -d '' IN
  now
  account
  NEW=()
  local rl= re='"(five_hour|seven_day[a-z_]*)":\{([^}]*)\}' body p r line w
  if [[ $IN =~ \"rate_limits\":\{(.*) ]]; then
    rl=${BASH_REMATCH[1]}
    rl=${rl%%'}}'*}'}'
    while [[ $rl =~ $re ]]; do
      rl=${rl#*"${BASH_REMATCH[0]}"}
      local n=${BASH_REMATCH[1]}
      body=${BASH_REMATCH[2]}
      [[ $body =~ \"used_percentage\":([0-9.]+) ]] && p=${BASH_REMATCH[1]} || continue
      [[ $body =~ \"resets_at\":([0-9]+) ]] && r=${BASH_REMATCH[1]} || continue
      NEW+=("$n:$p:$r")
    done
  fi
  if (( ${#NEW[@]} )); then record; else load_usage; fi
  describe
  line=${DESC//, / | }
  [[ $IN =~ \"context_window\":\{[^{}]*(\{[^{}]*\})?[^{}]*\"used_percentage\":([0-9.]+) ]] &&
    line+="${line:+ | }ctx ${BASH_REMATCH[2]%.*}%"
  if [[ $IN =~ \"session_id\":\"([^\"]+)\" ]]; then
    SID=${BASH_REMATCH[1]}
    if load_state && [[ $ON == 1 ]]; then
      if (( WAKE > NOW )); then
        clock "$WAKE"
        line+=" | paused to $CLOCK"
      else
        line+=" | guard ${M5/#0/-}/${M7/#0/-}"
      fi
    fi
  fi
  printf '%s\n' "$line"
}

case ${1:-} in
  statusline) statusline ;;
  arm) shift; arm "$@" ;;
  hook) hook ;;
  usage) usage ;;
  *) echo "usage: quotabeat.sh statusline | arm [args] | hook | usage" >&2; exit 64 ;;
esac
