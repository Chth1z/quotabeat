#!/usr/bin/env bash
# quotabeat: stops long or unattended Claude Code work at a mark below the plan's 5-hour and weekly usage limits,
# wakes it to go on once the window resets, and keeps its prompt cache warm while it waits. Offline: the usage comes
# from the headers of Claude Code's own API responses, as its debug log keeps them. One script, by role:
#
#   arm [args]  the !`...` line of SKILL.md, run when /quotabeat is invoked: this session's marks and heartbeats
#   hook        the skill's hooks, by event:
#                 PostToolUse       at a mark, tells Claude to wrap up and end the turn
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
LOGS=$CFG/debug
TTL=$(( 60 * U ))  # the prompt cache lives an hour after its last read
WARM=$(( TTL - 7 * U ))  # surely warm this long after a turn ends: the read came when its last response began, and a
                         # wake-up's request may be slow (a network coming back after sleep)
# Prices in tenths of fresh input, with the 1-hour cache: a heartbeat reads the cached conversation (1); a session that
# comes back to a cold cache writes it all again (20) where a warm one reads it (1).
CACHE_READ=1 CACHE_WRITE=20

now() { printf -v NOW '%(%s)T' -1 2> /dev/null || NOW=$(date +%s); }

clock() {  # CLOCK: the epoch $1 as people read it, 04:00 within half a day, Mon 09:00 further off
  local f='%H:%M'
  (( $1 - NOW >= 43200 )) && f='%a %H:%M'
  printf -v CLOCK "%($f)T" "$1" 2> /dev/null || CLOCK=$(date -d "@$1" +"$f" 2> /dev/null || date -r "$1" +"$f")
}

log() {
  [[ -f $DIR/debug ]] || return 0
  local t
  printf -v t '%(%F %T)T' -1 2> /dev/null || t=$(date '+%F %T')
  printf '%s %s %s %s\n' "$t" "$SID" "$$" "$*" >> "$DIR/debug.log"
}

# --- usage. Every API response carries the account's usage in its headers: anthropic-ratelimit-unified-5h-utilization
# (0.35 is 35%) and -5h-reset (an epoch), the same for 7d. With ANTHROPIC_LOG=debug the SDK inside Claude Code prints
# each response's headers, and DEBUG_SDK=1 keeps them: a terminal session in <config>/debug/<session>.txt, one line per
# response; the desktop app's sessions, with DEBUG_CLAUDE_AGENT_SDK=1 as well, in <config>/debug/sdk-*.txt, a line per
# header and not always in order. So each value is the last of its kind in the log's tail, and a desktop log counts
# only with this session's organization. (claude -p prints the headers to stdout instead: no reading there.)

read_usage() {  # WIN (window:percent:reset ...) from the newest response this session can see
  WIN=()
  local f files=("$LOGS/$SID.txt") org=${CLAUDE_CODE_ORGANIZATION_UUID:-} line k v o u5 r5 u7 r7 ro ru5 rr5 ru7 rr7
  [[ -n $org ]] && while IFS= read -r f; do files+=("$f"); done < <(ls -t "$LOGS"/sdk-*.txt 2> /dev/null | head -n 5)
  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    o= u5= r5= u7= r7= ro= ru5= rr5= ru7= rr7=
    while IFS= read -r line; do
      if [[ $line == "response start {" ]]; then
        if [[ $f != */sdk-* || $ro == "$org" ]]; then
          [[ -n $ro ]] && o=$ro
          [[ -n $ru5 ]] && u5=$ru5; [[ -n $rr5 ]] && r5=$rr5
          [[ -n $ru7 ]] && u7=$ru7; [[ -n $rr7 ]] && r7=$rr7
        fi
        ro= ru5= rr5= ru7= rr7=
        continue
      fi
      k=${line%%[\"\']*} v=${line##*[\"\']}
      case $k in
        *organization-id) ro=$v ;;
        *5h-utilization) ru5=$v ;;
        *5h-reset) rr5=$v ;;
        *7d-utilization) ru7=$v ;;
        *7d-reset) rr7=$v ;;
      esac
    done < <( { tail -c 131072 "$f" 2> /dev/null |
                grep -oE "response start \{|anthropic-(organization-id|ratelimit-unified-(5h|7d)-(utilization|reset))[\"']?: *[\"'][^\"']*";
                echo "response start {"; } )
    [[ $f == */sdk-* && $o != "$org" ]] && continue
    window five_hour "$u5" "$r5"
    window seven_day "$u7" "$r7"
    (( ${#WIN[@]} )) && return 0
  done
  return 1
}

window() {  # WIN += name:percent:reset, from a utilization like 0.35 (the percent rounded down) and an epoch
  [[ $3 =~ ^[0-9]+$ && $2 =~ ^([0-9]+)(\.([0-9]*))?$ ]] || return 0
  local f=${BASH_REMATCH[3]}00
  WIN+=("$1:$(( 10#${BASH_REMATCH[1]} * 100 + 10#${f:0:2} )):$3")
}

over() {  # HITS (window:percent:mark:reset:level ...): windows at or past their mark that haven't reset; level 2
          # once past the middle of the reserve above the mark
  HITS=()
  local w n p r m
  for w in "${WIN[@]}"; do
    n=${w%%:*} r=${w##*:} p=${w#*:} p=${p%%:*}
    case $n in five_hour) m=$M5 ;; seven_day) m=$M7 ;; *) continue ;; esac
    (( m > 0 && r > NOW && p >= m )) || continue
    HITS+=("$n:$p:$m:$r:$(( p >= (m + 100) / 2 ? 2 : 1 ))")
  done
}

name() {  # NAME: what people call a window
  case $1 in five_hour) NAME=5-hour ;; seven_day) NAME=weekly ;; *) NAME=$1 ;; esac
}

describe() {  # DESC: "5h 6% (04:00), 7d 94% (Mon 09:00)", from WIN
  DESC=
  local w n p r
  for w in "${WIN[@]}"; do
    n=${w%%:*} r=${w##*:} p=${w#*:} p=${p%%:*}
    case $n in five_hour) n=5h ;; seven_day) n=7d ;; esac
    if (( r > NOW )); then clock "$r"; DESC+="${DESC:+, }$n $p% ($CLOCK)"; else DESC+="${DESC:+, }$n 0%"; fi
  done
}

context_tokens() {  # CTX: this session's context size ("511k tokens") from its last response's usage in the transcript
  CTX=
  local f u i=0 c=0 r=0 total
  for f in "$CFG"/projects/*/"$SID".jsonl; do
    [[ -r $f ]] || continue
    u=$(tail -c 400000 "$f" | grep -oE '"usage":\{[^}]*' | tail -n 1)
    [[ $u =~ \"input_tokens\":([0-9]+) ]] && i=${BASH_REMATCH[1]}
    [[ $u =~ \"cache_creation_input_tokens\":([0-9]+) ]] && c=${BASH_REMATCH[1]}
    [[ $u =~ \"cache_read_input_tokens\":([0-9]+) ]] && r=${BASH_REMATCH[1]}
    total=$(( i + c + r ))
    (( total > 0 )) || continue
    if (( total >= 1000 )); then CTX="$(( (total + 500) / 1000 ))k tokens"; else CTX="$total tokens"; fi
    return 0
  done
  return 1
}

# --- a session's state, one line: m5 m7 beat idle active since gen wake armed noticed. No file: not armed.
#   m5 m7 beat idle  the marks (percent, 0 off), minutes between heartbeats (0 off), heartbeats after a stop
#   active since     1 once a real turn ran (a prompt, a tool call, arming, a wake-up) since the last Stop, -1 from a
#                    heartbeat until its own wake-up arrives (the desktop app hands that over as a prompt, which then
#                    is no real turn); when the last real turn ended: heartbeat k after it is due at since + k * beat,
#                    while k <= idle
#   gen wake         the waiting timer's process (0 none, -pid after a user prompt); when a paused session wakes (0 not
#                    paused)
#   armed noticed    when it was armed; the notices given, ",five_hour@<reset>:<level>,...", and ",blind" once told
#                    there is no reading

load_state() {
  S=$DIR/$SID
  [[ -r $S ]] && read -r M5 M7 BEAT IDLE ACTIVE SINCE GEN WAKE ARMED NOTICED < "$S"
}

save_state() {
  [[ -d $DIR ]] || mkdir -p "$DIR"
  printf '%s %s %s %s %s %s %s %s %s %s\n' "$M5" "$M7" "$BEAT" "$IDLE" "$ACTIVE" "$SINCE" "$GEN" "$WAKE" "$ARMED" \
    "$NOTICED" > "$S.$$" && mv -f "$S.$$" "$S"
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

NO_READING="Claude Code's debug log has no rate-limit headers for this session (they need ANTHROPIC_LOG=debug and DEBUG_SDK=1, in the desktop app also DEBUG_CLAUDE_AGENT_SDK=1, set before Claude Code starts; claude -p prints them to stdout instead)"

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
  ACTIVE=1 SINCE=0 GEN=0 WAKE=0 ARMED=$NOW NOTICED=-
  save_state
  local stop="stop at ${M5}% of the 5-hour window and ${M7}% of the weekly"
  (( M5 == 0 )) && stop="stop at ${M7}% of the weekly window (5-hour off)"
  (( M7 == 0 )) && stop="stop at ${M5}% of the 5-hour window (weekly off)"
  (( M5 == 0 && M7 == 0 )) && stop="no stop at a mark"
  local beat="a heartbeat every $BEAT minutes while the session waits: $IDLE after a stop, all the way through a quota pause when that costs less than a cold cache"
  (( IDLE == 0 )) && beat="a heartbeat every $BEAT minutes through a quota pause when that costs less than a cold cache, none after other stops"
  (( BEAT == 0 )) && beat="no heartbeats"
  local usage
  if read_usage; then
    describe
    usage="Usage now: $DESC."
  elif [[ ${ANTHROPIC_LOG:-} == debug && -n ${DEBUG_SDK:-}${DEBUG:-} &&
          ( -z ${CLAUDE_CODE_ORGANIZATION_UUID:-} || -n ${DEBUG_CLAUDE_AGENT_SDK:-} ) ]]; then
    usage="No usage reading yet: waiting for this session's first response (claude -p prints headers to stdout instead)."
  else
    usage="No usage reading yet: $NO_READING, so nothing stops this session at a mark until they come."
  fi
  echo "quotabeat on: $stop; $beat. $usage$note${bad:+ Ignored:$bad.}"
}

# --- hooks

post() {  # PostToolUse, in the background: the notice at a mark
  load_state || return 0
  local msg= changed=0 h n p m r l key until=0
  (( ACTIVE > 0 )) || ACTIVE=1 changed=1  # a tool ran: a real turn
  now
  if ! read_usage && (( NOW - ARMED >= 2 * U )) && [[ $NOTICED != *,blind* ]]; then
    NOTICED+=,blind changed=1
    msg="No usage reading: $NO_READING, so nothing stops this session at a mark. Tell the user in one line."
  fi
  over
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
    if (( BEAT )); then
      local need=$(( (until + U - NOW - WARM + BEAT * U - 1) / (BEAT * U) ))
      if (( need * CACHE_READ >= CACHE_WRITE - CACHE_READ )); then
        context_tokens
        msg+=" No heartbeats will run during this wait ($need beats would cost more than a cold cache); briefly tell the user${CTX:+ that the context is at ~$CTX} and ask whether they want to /compact."
      fi
    fi
  fi
  (( changed )) && { prune; save_state; }
  [[ -n $msg ]] || return 0
  log "notice: $msg"
  printf '%s\n' "$msg" >&3
  return 2
}

stop() {  # Stop, in the background: the timer
  load_state || return 0
  (( ACTIVE < 0 )) && { ACTIVE=0; save_state; }
  now
  local t=$NOW s0="$M5:$M7:$BEAT:$IDLE:$SINCE:$GEN:$WAKE:$ARMED" h n r l told=0 wake=0 next=0 need k names=
  sleep 2  # the turn's last tool's PostToolUse lands first
  load_state || return 0
  [[ "$M5:$M7:$BEAT:$IDLE:$SINCE:$GEN:$WAKE:$ARMED" == "$s0" ]] || { log "gave way"; return 0; }
  now
  (( ACTIVE > 0 )) && SINCE=$t  # a real turn ended: the heartbeats after a stop count from here
  ACTIVE=0
  read_usage
  over
  prune
  for h in "${HITS[@]}"; do
    n=${h%%:*} r=${h#*:*:*:} l=${r#*:} r=${r%%:*}
    [[ ,$NOTICED, == *",$n@"* ]] && told=1
    (( r > wake )) && wake=$r
    name "$n"
    names+="${names:+ and }$NAME"
  done
  if (( told )); then
    for h in "${HITS[@]}"; do
      n=${h%%:*} r=${h#*:*:*:} l=${r#*:} r=${r%%:*}
      [[ ,$NOTICED, == *",$n@$r:$l,"* ]] || NOTICED+=,$n@$r:$l
    done
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
        if (( ACTIVE < 0 )); then ACTIVE=0; else ACTIVE=1 GEN=-$$; fi
        save_state
      fi ;;
    SessionEnd) rm -f "$DIR/$SID" ;;
  esac
}

case ${1:-} in
  arm) shift; arm "$@" ;;
  hook) hook ;;
  *) echo "usage: quotabeat.sh arm [args] | hook" >&2; exit 64 ;;
esac
