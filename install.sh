#!/usr/bin/env bash
# Puts quotabeat into Claude Code: copies the skill into the skills folder and makes quotabeat.sh the status line,
# which is where the usage readings come from.
#
#   bash install.sh             install or update; a status line set before stays (see --replace)
#   bash install.sh --replace   put quotabeat's status line in place of the one set before, which is kept
#   bash install.sh uninstall   put the status line back as it was (the skill's files stay)

shopt -u patsub_replacement 2> /dev/null  # (bash 5.2+: else & and \ in a ${x/a/b} replacement change meaning)
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CFG=${CFG//\\//}
SRC=$(cd "$(dirname "$0")" && pwd -P)
DST=$CFG/skills/quotabeat
SETTINGS=$CFG/settings.json
SAVED=$CFG/quotabeat/statusline-before.json
SCRIPT=$DST/quotabeat.sh
command -v cygpath > /dev/null && SCRIPT=$(cygpath -m "$SCRIPT")  # Windows: C:/Users/..., which every shell reads
printf -v OURS '{"type": "command", "command": "bash \\"%s\\" statusline"}' "$SCRIPT"
RE='"statusLine"[[:space:]]*:[[:space:]]*(\{[^{}]*\})'

json='{}'
[[ -s $SETTINGS ]] && IFS= read -r -d '' json < "$SETTINGS"
cur=
if [[ $json =~ $RE ]]; then
  cur=${BASH_REMATCH[1]}
elif [[ $json == *'"statusLine"'* ]]; then
  echo "settings.json has a statusLine this script can't edit safely; set it by hand to: $OURS" >&2
  exit 1
fi

write() {
  mkdir -p "$CFG" && printf '%s' "$json" > "$SETTINGS.$$" && mv -f "$SETTINGS.$$" "$SETTINGS"
}

if [[ ${1:-} == uninstall ]]; then
  if [[ $cur != *quotabeat.sh* ]]; then
    echo "the status line isn't quotabeat's: left as it is"
    exit 0
  fi
  if [[ -r $SAVED ]]; then
    json=${json/"$cur"/$(< "$SAVED")}
    rm -f "$SAVED"
  else  # the entry goes, with the comma that joined it to a neighbour
    for re in ',[[:space:]]*"statusLine"[[:space:]]*:[[:space:]]*\{[^{}]*\}' '"statusLine"[[:space:]]*:[[:space:]]*\{[^{}]*\}[[:space:]]*,?'; do
      [[ $json =~ $re ]] && { json=${json/"${BASH_REMATCH[0]}"/}; break; }
    done
  fi
  write && echo "status line restored"
  exit 0
fi

if [[ $SRC != "$(cd "$DST" 2> /dev/null && pwd -P)" ]]; then
  mkdir -p "$DST" && cp "$SRC/SKILL.md" "$SRC/quotabeat.sh" "$DST/" || exit 1
fi
if [[ -z $cur ]]; then
  if [[ $json =~ ^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$ ]]; then
    json="{
  \"statusLine\": $OURS
}"
  else
    json="{
  \"statusLine\": $OURS,${json#*\{}"
  fi
elif [[ $cur != *quotabeat.sh* ]]; then
  if [[ ${1:-} != --replace ]]; then
    echo "settings.json already has a status line: $cur" >&2
    echo "Run install.sh --replace to put quotabeat's in its place (yours is kept for uninstall), or have yours also pipe its input to: bash \"$SCRIPT\" statusline" >&2
    exit 1
  fi
  mkdir -p "${SAVED%/*}" && printf '%s\n' "$cur" > "$SAVED"
  json=${json/"$cur"/$OURS}
else
  json=${json/"$cur"/$OURS}
fi
write && echo "quotabeat installed in $DST; status line: bash \"$SCRIPT\" statusline"
