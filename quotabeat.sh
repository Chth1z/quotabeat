#!/usr/bin/env bash
# quotabeat: stops long or unattended Claude Code work at a mark below the plan's 5-hour and weekly usage limits,
# wakes it to go on once the window resets, and keeps its prompt cache warm while it waits. Offline: the usage comes
# from Claude Code itself. One script, by role:
#
#   statusline  the statusLine command: every response hands Claude Code the account's usage (rate_limits); this keeps
#               it in <config>/quotabeat/usage-<account> and prints the status line
#   usage       PostToolUse of the desktop app's get_usage tool (the desktop app runs no status line): records the usage
#               it reports and, when quotabeat asked for the call, hands Claude one line in place of the report
#   arm [args]  the !`...` line of SKILL.md, run when /quotabeat is invoked: this session's marks and heartbeats
#   hook        the skill's hooks, by event:
#                 PostToolUse       at a mark, tells Claude to wrap up and end the turn; in the desktop app, asks for
#                                   a usage check when one is due
#                 Stop              the timer: after a turn told to stop at a mark, waits for the reset and wakes the
#                                   session to go on, with heartbeats through the pause where they cost less than a
#                                   cold cache; after any other turn, IDLE heartbeats, one every BEAT minutes
#                 UserPromptSubmit  the user wrote: a waiting timer gives way
#                 SessionEnd        forgets the session
#
# PostToolUse and Stop run in the background (asyncRewake): exit 2 wakes Claude with what the hook wrote to stderr. A
# heartbeat is such a wake-up with nothing to do: its request reads the conversation from the prompt cache at a tenth
# of the price of fresh input, which renews the cache's hour; Claude answers "." and that turn's Stop starts the next
# timer. The newest timer wins; older ones give way when they wake. A heartbeat goes out only while the cache is surely
# still warm: after the machine slept past that, one would only pay to write the cache again.
#
# Bash 3.2+ and coreutils (Git Bash on Windows). QUOTABEAT_UNIT is the seconds in a minute (the tests shorten it); a
# file <config>/quotabeat/debug makes the hooks log what they do to debug.log beside it.

LC_ALL=C
shopt -u patsub_replacement 2> /dev/null  # (bash 5.2+: else & in a ${x/a/b} replacement stands for the match)
U=${QUOTABEAT_UNIT:-60}
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG=${CFG//\\//}
DIR=$CFG/quotabeat
TTL=$(( 60 * U ))  # the prompt cache lives an hour after its last read
WARM=$(( TTL - 7 * U ))  # surely warm this long after a turn ends: the read came when its last response began, and a
                         # wake-up's request may be slow (a network coming back after sleep)
# Prices in tenths of fresh input, with the 1-hour cache: a heartbeat reads the cached conversation (1); a session that
# comes back to a cold cache writes it all again (20) where a warm one reads it (1).
CACHE_READ=1 CACHE_WRITE=20
USAGE_TOOL=mcp__ccd_session_mgmt__get_usage

now() { printf -v NOW '%(%s)T' -1 2> /dev/null || NOW=$(date +%s); }

clock() {  # CLOCK: the epoch $1 as people read it, 04:00 within half a day, Mon 09:00 further off
  local f='%H:%M'
  (( $1 - NOW >= 43200 )) && f='%a %H:%M'
  printf -v CLOCK "%($f)T" "$1" 2> /dev/null || CLOCK=$(date -d "@$1" +"$f" 2> /dev/null || date -r "$1" +"$f")
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

log() {
  [[ -f $DIR/debug ]] || return 0
  local t
  printf -v t '%(%F %T)T' -1 2> /dev/null || t=$(date '+%F %T')
  printf '%s %s %s %s\n' "$t" "$SID" "$$" "$*" >> "$DIR/debug.log"
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

# --- a session's state, one line: m5 m7 beat idle active since gen wake acct desk armed asked noticed. No file: not
# armed.
#   m5 m7 beat idle  the marks (percent, 0 off), minutes between heartbeats (0 off), heartbeats after a stop
#   active since     1 once a real turn ran (a prompt, a tool call, arming, a wake-up) since the last Stop, -1 from a
#                    heartbeat until its own wake-up arrives (the desktop app hands that over as a prompt, which then
#                    is no real turn); when the last real turn ended: heartbeat k after it is due at since + k * beat,
#                    while k <= idle
#   gen wake         the waiting timer's process (0 none); when a paused session wakes (0 not paused)
#   acct desk        the account whose readings count; 1 in the desktop app, which runs no status line
#   armed asked      when it was armed; when it last asked for a usage check (desktop app)
#   noticed          the notices given, ",five_hour@<reset>:<level>,..."; ",blind" once told there is no reading

load_state() {
  S=$DIR/$SID
  [[ -r $S ]] && read -r M5 M7 BEAT IDLE ACTIVE SINCE GEN WAKE ACCT DESK ARMED ASKED NOTICED < "$S"
}

save_state() {
  [[ -d $DIR ]] || mkdir -p "$DIR"
  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$M5" "$M7" "$BEAT" "$IDLE" "$ACTIVE" "$SINCE" "$GEN" "$WAKE" \
    "$ACCT" "$DESK" "$ARMED" "$ASKED" "$NOTICED" > "$S.$$" && mv -f "$S.$$" "$S"
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

# --- arm: /quotabeat [5-hour mark] [weekly mark] [5h=N] [week=N] [beat=minutes] [idle=count], N or off; or stop

arm() {
  SID=${CLAUDE_CODE_SESSION_ID:-}
  if [[ -z $SID ]]; then
    echo "quotabeat: no session id here (CLAUDE_CODE_SESSION_ID), so nothing was armed."
    return 0
  fi
  S=$DIR/$SID
  M5=87 M7=97 BEAT=47 IDLE=7
  local t k v pos=0 off=0 bad=
  shopt -s nocasematch
  for t in "$@"; do
    case $t in stop|off) off=1; continue ;; esac
    k= v=${t%\%}
    [[ $v == *=* ]] && k=${v%%=*} v=${v#*=}
    [[ $v == off ]] && v=0
    if [[ -z $v || $v == *[!0-9]* || ${#v} -gt 3 ]]; then bad+=" $t"; continue; fi
    if [[ -z $k ]]; then
      case $(( pos++ )) in 0) k=5h ;; 1) k=week ;; esac
    fi
    case $k in
      5h) M5=$(( 10#$v )) ;;
      week) M7=$(( 10#$v )) ;;
      beat) BEAT=$(( 10#$v )) ;;
      idle) IDLE=$(( 10#$v )) ;;
      *) bad+=" $t" ;;
    esac
  done
  shopt -u nocasematch
  if (( off )); then
    rm -f "$S"
    echo "quotabeat is off for this session: no stop at a mark, no heartbeat."
    return 0
  fi
  (( M5 > 100 )) && M5=100
  (( M7 > 100 )) && M7=100
  (( BEAT && BEAT < 5 )) && BEAT=5
  (( BEAT * U > WARM )) && BEAT=$(( WARM / U ))  # (53) no heartbeat goes out later than that after the last read
  local note= f g
  # A session whose prompt cache lives 5 minutes gains nothing from a heartbeat every 47.
  for f in "$CFG"/projects/*/"$SID".jsonl; do
    [[ -r $f ]] || continue
    g=$(tail -c 400000 "$f" | grep -o '"cache_creation":{[^}]*}' | tail -n 1)
    if [[ $g =~ \"ephemeral_5m_input_tokens\":[1-9] && ! $g =~ \"ephemeral_1h_input_tokens\":[1-9] ]]; then
      BEAT=0 note=" Heartbeat off: this session's prompt cache lasts 5 minutes, a heartbeat can't keep it."
    fi
  done
  now
  account
  ACTIVE=1 SINCE=0 GEN=0 WAKE=0 DESK=0 ARMED=$NOW ASKED=0 NOTICED=-
  [[ ${CLAUDE_CODE_ENTRYPOINT:-} == claude-desktop ]] && DESK=1
  load_usage
  (( DESK && ! TAKEN )) && ASKED=$NOW  # the line below asks for a check: its report gets shortened too
  save_state
  local stop="stop at ${M5}% of the 5-hour window and ${M7}% of the weekly"
  (( M5 == 0 )) && stop="stop at ${M7}% of the weekly window (5-hour off)"
  (( M7 == 0 )) && stop="stop at ${M5}% of the 5-hour window (weekly off)"
  (( M5 == 0 && M7 == 0 )) && stop="no stop at a mark"
  local beat="a heartbeat every $BEAT minutes while the session waits: $IDLE after a stop, all the way through a quota pause when that costs less than a cold cache"
  (( IDLE == 0 )) && beat="a heartbeat every $BEAT minutes through a quota pause when that costs less than a cold cache, none after other stops"
  (( BEAT == 0 )) && beat="no heartbeats"
  local usage
  if (( TAKEN )); then
    describe
    usage="Usage now: $DESC."
  elif (( DESK )); then
    usage="No usage reading for this account yet (the desktop app runs no status line): call $USAGE_TOOL once now; quotabeat reads its result."
  else
    usage="No usage reading for this account yet: it comes with the next response if the statusLine is quotabeat's (see its README); until then nothing stops this session."
  fi
  echo "quotabeat on: $stop; $beat. $usage$note${bad:+ Ignored:$bad.}"
}

# --- hooks

post() {  # PostToolUse, in the background: the notice at a mark, and in the desktop app the call for a usage check
  load_state || return 0
  local msg= changed=0
  (( ACTIVE > 0 )) || ACTIVE=1 changed=1  # a tool ran: a real turn
  if [[ $IN == *"\"tool_name\":\"$USAGE_TOOL\""* ]]; then  # its own hook reads it
    (( changed )) && save_state
    return 0
  fi
  now
  load_usage
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
    (( r > until )) && until=$r
    if (( l == 1 )); then
      msg+="${msg:+ }The $NAME usage is $p%, at its $m% mark."
    else
      msg+="${msg:+ }The $NAME usage is $p%, well past its $m% mark: end the turn now."
    fi
  done
  if (( until )); then
    clock $(( until + U ))
    msg+=" Finish or checkpoint the step at hand, note what comes next, and end the turn without waiting yourself: the session wakes by itself at $CLOCK, after the reset."
  fi
  (( changed )) && { prune; save_state; }
  [[ -n $msg ]] || return 0
  log "notice: $msg"
  printf '%s\n' "$msg" >&3
  return 2
}

stop() {  # Stop, in the background: the timer
  [[ -r $DIR/$SID ]] || return 0
  now
  local t=$NOW h n r told=0 wake=0 next=0 need k names=  # t: the turn's last request read the cache just before
  sleep 2  # the turn's last reading lands a moment after Stop (the status line runs 300 ms after a response)
  load_state || return 0
  now
  (( ACTIVE > 0 )) && SINCE=$t  # a real turn ended: the heartbeats after a stop count from here
  ACTIVE=0
  load_usage
  over
  prune
  for h in "${HITS[@]}"; do
    n=${h%%:*} r=${h#*:*:*:} r=${r%%:*}
    [[ ,$NOTICED, == *",$n@"* ]] && told=1
    (( r > wake )) && wake=$r
    name "$n"
    names+="${names:+ and }$NAME"
  done
  if (( told )); then
    # Told to stop at a mark: wake a minute after the reset (the later one, with two windows at their marks). Bridging
    # the pause takes a heartbeat before each stretch without a cache read outgrows WARM; worth it only if they cost
    # less than writing the cache again when the session wakes cold. Then all of them, else none.
    wake=$(( wake + U )) next=$wake
    if (( BEAT )); then
      need=$(( (wake - t - WARM + BEAT * U - 1) / (BEAT * U) ))  # rounded up; 0 or less: the cache outlasts the pause
      (( need > 0 && need * CACHE_READ < CACHE_WRITE - CACHE_READ )) && next=$(( t + BEAT * U ))
    fi
  else
    wake=0
    if (( BEAT )); then  # heartbeat k after the last real stop is due at SINCE + k * BEAT: the time gone is the count
      k=$(( (t - SINCE) / (BEAT * U) + 1 ))
      (( k <= IDLE )) && next=$(( SINCE + k * BEAT * U ))
    fi
  fi
  WAKE=$wake GEN=0
  (( next )) && GEN=$$
  save_state
  log "stop: since $SINCE, wake $wake, next $next"
  (( next )) || return 0
  while :; do
    # A minute at most per sleep, then a look at the clock: a sleep may not count the time the machine is asleep.
    while now; (( NOW < next )); do sleep $(( next - NOW < U ? next - NOW : U )); done
    load_state || { log "disarmed"; return 0; }
    [[ $GEN == "$$" ]] || { log "gave way"; return 0; }  # a newer turn's timer, or the user wrote
    if (( next == wake )); then
      ACTIVE=1 WAKE=0
      prune
      save_state
      log "wake-up"
      printf 'The %s window has reset: go on with the paused work.\n' "$names" >&3
      return 2
    fi
    if (( NOW - t <= WARM )); then
      ACTIVE=-1
      save_state
      log "heartbeat"
      echo 'heartbeat: reply with exactly . and nothing else.' >&3
      return 2
    fi
    # The machine slept past the time the cache is surely warm: a heartbeat now might only pay to write it again.
    log "cache may be cold"
    (( wake )) || return 0
    next=$wake
  done
}

hook() {
  exec 3>&2 2> /dev/null  # on exit 2 Claude reads stderr: only the note goes there (fd 3), never a stray error
  IFS= read -r -d '' -n 16384 IN  # the fields used come first; a tool's output can run long
  (( ${#IN} >= 16384 )) && cat > /dev/null
  [[ $IN =~ \"session_id\":\"([^\"]+)\" ]] || return 0
  SID=${BASH_REMATCH[1]}
  [[ $IN =~ \"hook_event_name\":\"([A-Za-z]+)\" ]] || return 0
  local event=${BASH_REMATCH[1]}
  [[ $event == PostToolUse ]] || log "$event"
  case $event in
    PostToolUse) post ;;
    Stop) stop ;;
    UserPromptSubmit)  # in the desktop app a heartbeat's own wake-up comes this way too: that one is no real turn
      if load_state; then
        if (( ACTIVE < 0 )); then ACTIVE=0; else ACTIVE=1 GEN=0; fi
        save_state
      fi ;;
    SessionEnd) rm -f "$DIR/$SID" ;;
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
  log "usage: ${NEW[*]}"
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
    if load_state; then
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
