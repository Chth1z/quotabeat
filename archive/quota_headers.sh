#!/usr/bin/env bash
# quota_headers.sh: 零联网、零 Python、零侵入，从 claude.exe 内置 SDK 的 /v1/messages 响应头日志中提取双端实时额度
# 依赖: Bash 3.2+ & coreutils (Windows Git Bash)
#
# 前置环境变量 (一次性设置在 Windows 用户环境变量中，双端自动继承):
#   ANTHROPIC_LOG=debug
#   DEBUG=1
#   DEBUG_CLAUDE_AGENT_SDK=1

LC_ALL=C
shopt -u patsub_replacement 2> /dev/null

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG=${CFG//\\//}
DIR=$CFG/quotabeat

now() { printf -v NOW '%(%s)T' -1 2> /dev/null || NOW=$(date +%s); }

clock() {
  local f='%H:%M'
  (( $1 - NOW >= 43200 )) && f='%a %H:%M'
  printf -v CLOCK "%($f)T" "$1" 2> /dev/null || CLOCK=$(date -d "@$1" +"$f" 2> /dev/null || date -r "$1" +"$f")
}

# 纯 Bash 将 0~1 的小数 (如 "0.25", "0.875", "1") 四舍五入为整数百分比 (25, 88, 100)
frac_to_pct() {
  local u=$1 int frac permille
  int=${u%%.*}
  frac=${u#*.}
  [[ $u == *.* ]] || frac=0
  frac="${frac}000"
  permille=$(( 10#${int:-0} * 1000 + 10#${frac:0:3} ))
  PCT=$(( (permille + 5) / 10 ))
}

# 根据响应头中的 anthropic-organization-id ($1) 反查 accountUuid，区分 CLI 与 Desktop 不同登录账号
resolve_account() {
  local org=${1:-} f="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" j= d tmp
  f=${f//\\//}
  ACCT=

  # 1. 若 .claude.json 中的 organizationUuid 与当前响应头的 org 一致，则取其 accountUuid
  if [[ -r $f ]]; then
    IFS= read -r -d '' j < "$f"
    if [[ -z $org || $j == *"\"organizationUuid\": \"$org\""* || $j == *"\"organizationUuid\":\"$org\""* ]]; then
      [[ $j =~ \"accountUuid\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && ACCT=${BASH_REMATCH[1]}
    fi
  fi

  # 2. 若未匹配（例如 Desktop 登录了另一个账号），直接从 Desktop 会话目录树 <accountUuid>/<orgUuid> 反查
  if [[ -z $ACCT && -n $org ]]; then
    local la=${LOCALAPPDATA:-} ap=${APPDATA:-}
    la=${la//\\//} ap=${ap//\\//}
    for d in "$la"/Claude-Data/*/claude-code-sessions/*/"$org" \
             "$la"/Claude-Data/*/local-agent-mode-sessions/*/"$org" \
             "$ap"/Claude/claude-code-sessions/*/"$org" \
             "$ap"/Claude/local-agent-mode-sessions/*/"$org"; do
      if [[ -d $d ]]; then
        tmp=${d%/"$org"}
        ACCT=${tmp##*/}
        break
      fi
    done
  fi

  # 3. 兜底使用环境变量或 orgUuid 本身（保证不同账号绝不串台）
  ACCT=${ACCT:-${CLAUDE_CODE_ACCOUNT_UUID:-${org:-default}}}
}

# 从 ~/.claude/debug/*.txt 尾部提取最新一次 /v1/messages 的响应头
# 参数 $1: 可选的 session_id (优先检查当前会话日志，其次按修改时间检查最新 5 个日志，兼容 Desktop 的 sdk-<uuid>.txt)
pull_from_debug() {
  local sid=${1:-${CLAUDE_CODE_SESSION_ID:-}} files=() f raw block org= pair k name re_u re_r u r
  NEW=() ORG= STATUS= SRC_LOG=

  [[ -n $sid && -r $CFG/debug/$sid.txt ]] && files+=("$CFG/debug/$sid.txt")
  while IFS= read -r f; do
    [[ -n $f && $f != "$CFG/debug/$sid.txt" ]] && files+=("$f")
  done < <(ls -t "$CFG/debug"/*.txt 2> /dev/null | head -n 5)

  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    raw=$(tail -c 65536 "$f" 2> /dev/null)
    [[ $raw == *"response start"* && $raw == *"anthropic-ratelimit-unified-"* ]] || continue

    # 截取最后一次 "response start" 到 "durationMs" 之间的 headers 块
    block=${raw##*response start}
    block=${block%%durationMs*}

    # 统一剥离反斜杠并将单引号转为双引号，抹平 CLI 单行转义与 Desktop 多行格式的差异
    block=${block//\\/}
    block=${block//\'/\"}

    [[ $block =~ \"?anthropic-organization-id\"?:[[:space:]]*\"([^\"]+)\" ]] && org=${BASH_REMATCH[1]}
    [[ $block =~ \"?anthropic-ratelimit-unified-status\"?:[[:space:]]*\"([^\"]+)\" ]] && STATUS=${BASH_REMATCH[1]}

    for pair in "5h:five_hour" "7d:seven_day" "7d_oi:seven_day_overage_included"; do
      k=${pair%%:*} name=${pair#*:}
      re_u="\"?anthropic-ratelimit-unified-${k}-utilization\"?:[[:space:]]*\"([0-9.]+)\""
      re_r="\"?anthropic-ratelimit-unified-${k}-reset\"?:[[:space:]]*\"([0-9]+)\""
      if [[ $block =~ $re_u ]]; then
        u=${BASH_REMATCH[1]}
        if [[ $block =~ $re_r ]]; then
          r=${BASH_REMATCH[1]}
          frac_to_pct "$u"
          NEW+=("$name:$PCT:$r")
        fi
      fi
    done

    if (( ${#NEW[@]} )); then
      ORG=$org
      SRC_LOG=${f##*/}
      resolve_account "$ORG"
      return 0
    fi
  done
  return 1
}

# 与 quotabeat.sh 完全一致的读取与合并逻辑（写到 ~/.claude/quotabeat/usage-$ACCT）
load_usage() {
  TAKEN=0 WIN=()
  local f=()
  [[ -r $DIR/usage-$ACCT ]] && read -ra f < "$DIR/usage-$ACCT" && TAKEN=${f[0]:-0} WIN=("${f[@]:1}")
}

record() {
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

describe() {
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

case ${1:-show} in
  show|poll)
    now
    if pull_from_debug "${2:-}"; then
      record
      describe
      printf 'acct=%s org=%s src=%s status=%s | %s\n' "$ACCT" "${ORG:--}" "$SRC_LOG" "${STATUS:-allowed}" "$DESC"
    else
      echo "未在 $CFG/debug/*.txt 中找到 /v1/messages 响应头记录（请确认已开启 ANTHROPIC_LOG=debug、DEBUG=1、DEBUG_CLAUDE_AGENT_SDK=1 并产生过至少一次对话）。" >&2
      exit 1
    fi
    ;;
  hook)
    # 可直接作为 PostToolUse / Stop 钩子静默更新额度文件
    IFS= read -r -d '' -n 16384 IN
    (( ${#IN} >= 16384 )) && cat > /dev/null
    SID=
    [[ $IN =~ \"session_id\":\"([^\"]+)\" ]] && SID=${BASH_REMATCH[1]}
    now
    pull_from_debug "$SID" && record
    exit 0
    ;;
  *)
    echo "usage: quota_headers.sh [show [session_id] | hook]" >&2
    exit 64
    ;;
esac
