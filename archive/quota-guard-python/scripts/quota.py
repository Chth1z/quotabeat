#!/usr/bin/env python3
"""quota-guard: the Claude plan's 5-hour and weekly usage, read without asking any server, and a guard that pauses a
Claude Code session at a mark and wakes it once the window resets.

Every API response tells Claude Code the account's usage, and Claude Code hands it to the status line command
(rate_limits: five_hour, seven_day, and behind a gateway spend_limit). `statusline` writes it to quota_live.json in the
config folder, tagged with the account: the desktop app can be signed in to another account than the terminal, on the
same folder. Usage only grows inside a window, so within one the larger reading stands (an idle session's line, run
again on its old data, cannot lower what a working one wrote), and a later window supersedes an earlier one.

The guard is the skill's hooks (SKILL.md), armed per session by `/quota-guard [5h mark] [weekly mark]`, which the
hooks read from the transcript, so arming starts nothing:
  PostToolUse  once a window is at its mark, tells Claude to stop at a safe point and end the turn;
  Stop         in the background (asyncRewake): if the turn ended at a mark, starts QUOTA_GUARD_ON_PAUSE once, waits
               for the reset and wakes the session (exit 2, the message on stderr);
  SessionEnd   forgets the session, so a waiting hook ends instead of waking the next conversation.
A session that doesn't run the status line (the desktop app, `claude -p`) has a reading only while a terminal session
of the same account writes one; the guard says so instead of guessing.

Usage:
  quota.py statusline            the statusLine command (Claude Code's JSON on stdin)
  quota.py hook                  the skill's hooks (the hook's JSON on stdin)
  quota.py status                this account's usage and, inside a session, its guard
  quota.py install [--replace]   copy the skill into the skills folder, pin this Python in its hooks, set the statusLine
  quota.py uninstall             put the statusLine back as it was
QUOTA_GUARD_FAST=1 shortens the guard's waits (tests).
"""
import datetime
import json
import os
import re
import sys
import time

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = {"five_hour": ("5h", "5-hour"), "seven_day": ("7d", "weekly"), "spend_limit": ("spend", "spend-limit")}
LABELS = {"5h": "five_hour", "hour": "five_hour", "five_hour": "five_hour",
          "week": "seven_day", "weekly": "seven_day", "w": "seven_day", "7d": "seven_day", "seven_day": "seven_day",
          "spend": "spend_limit", "spend_limit": "spend_limit"}
DEFAULT_MARKS = {"five_hour": 87.0, "seven_day": 95.0, "spend_limit": None}
FAST = bool(os.environ.get("QUOTA_GUARD_FAST"))
SAME_WINDOW = 600            # two readings whose resets lie within ten minutes are of one window
STALE = 600                  # a reading this much older than the session's newest reply doesn't cover the session
GRACE = 120                  # how long an armed session works before a missing reading is worth a word
MARGIN = 0 if FAST else 60   # the wake-up comes this long after the reset
SETTLE = 0 if FAST else 2    # the turn's last reading lands a moment after Stop (the status line's 300 ms debounce)
TICK = 0.1 if FAST else 30   # how often a waiting Stop hook checks it is still wanted
FIRST_LOOK = 4 << 20         # a session's first scan reads only the transcript's tail: the arming invocation is recent


def config_dir():
    return os.path.normpath(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"))


def live_path():
    return os.path.join(config_dir(), "quota_live.json")


def state_path(session):
    return os.path.join(config_dir(), "quota-guard", re.sub(r"[^\w.-]", "_", session) + ".json")


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, TypeError, ValueError):
        return None


def save(path, data, **dump):
    """Writes atomically; Windows refuses the replace while a reader holds the file, so it tries a few times."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, **dump)
    for _ in range(25):
        try:
            os.replace(tmp, path)
            return True
        except PermissionError:
            time.sleep(0.02)
    os.remove(tmp)
    return False


def iso(t):
    return datetime.datetime.fromtimestamp(float(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def clock(t, now):
    """A local time as people read it: 04:19 within half a day, Mon 09:00 further off."""
    return time.strftime("%H:%M" if t - now < 12 * 3600 else "%a %H:%M", time.localtime(t))


def span(seconds):
    minutes = max(0, int(seconds)) // 60
    days, hours = divmod(minutes // 60, 24)
    return "%dd%dh" % (days, hours) if days else "%dh%02dm" % (hours, minutes % 60) if hours else "%dm" % minutes


def account():
    """The account this Claude Code signs in as: the desktop app and the SDK pass it in the environment; a terminal's
    own login is in .claude.json."""
    uuid = os.environ.get("CLAUDE_CODE_ACCOUNT_UUID")
    if uuid:
        return uuid
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~")
    return ((load(os.path.join(home, ".claude.json")) or {}).get("oauthAccount") or {}).get("accountUuid")


def reading():
    """This account's latest reading ({"fetched_at", window: {"utilization", "resets_at"}}), or None: there is none
    yet, or the newest is another account's."""
    live = load(live_path())
    return live if live and live.get("account") == account() else None


def windows(live, now):
    """(window, percent, reset epoch or None) for each window of a reading; one past its reset reads 0, the new
    window's usage until the next response says otherwise."""
    for name in WINDOWS:
        w = (live or {}).get(name)
        if w and w.get("utilization") is not None:
            reset = epoch(w["resets_at"]) if w.get("resets_at") else None
            yield name, 0.0 if reset is not None and reset <= now else float(w["utilization"]), reset


def over(live, marks, now):
    """The windows at or past their marks: (window, percent, mark, reset). One without a reset time can't be waited
    out, so it doesn't count."""
    return [(name, pct, marks[name], reset) for name, pct, reset in windows(live, now)
            if marks.get(name) is not None and reset is not None and pct >= marks[name]]


def larger(old, new):
    """Of two readings of a window the one that stands: within one window the larger, else the later window."""
    if not (old and old.get("resets_at") and new.get("resets_at")):
        return new
    gap = epoch(new["resets_at"]) - epoch(old["resets_at"])
    if abs(gap) < SAME_WINDOW:
        return old if old["utilization"] > new["utilization"] else new
    return new if gap > 0 else old


def record(new, session):
    """Writes a response's usage; returns the reading that stands."""
    me = account()
    old = load(live_path()) or {}
    mine = old.get("account") == me
    out = {"account": me, "session": session, "fetched_at": time.time()}
    for name in WINDOWS:
        prev = old.get(name) if mine else None
        out[name] = larger(prev, new[name]) if name in new else prev
    save(live_path(), out)
    return out


def skill_name():
    """The skill's name, from its SKILL.md: the hooks look for invocations by it."""
    try:
        with open(os.path.join(SKILL_DIR, "SKILL.md"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("name:"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "quota-guard"


def mark(word):
    """A mark as typed: a percentage (87, 87%) or off (None); False when it is neither."""
    if word in ("off", "none", "no", "-"):
        return None
    try:
        return float(word.rstrip("%"))
    except ValueError:
        return False


def parse(args):
    """What an invocation asks: ("arm", marks), ("stop", None) or ("status", None). Bare numbers are the 5-hour mark,
    then the weekly one, then the spend limit's; label=value (or label value) names one (5h, week, spend); off turns
    one off; a window not mentioned keeps its default."""
    words = re.findall(r"[^\s,;]+", (args or "").lower())
    if "stop" in words or "disarm" in words or words == ["off"]:
        return "stop", None
    if words and all(w in ("status", "check") for w in words):
        return "status", None
    marks, said, label = dict(DEFAULT_MARKS), set(), None
    for word in words:
        pair = re.match(r"^(\w+)[=:](.+)$", word)
        if pair and pair.group(1) in LABELS:
            label, word = LABELS[pair.group(1)], pair.group(2)
        elif word in LABELS:
            label = LABELS[word]
            continue
        value = mark(word)
        if value is False:
            label = None
            continue
        label = label or next((n for n in WINDOWS if n not in said), None)
        if label:
            marks[label] = value
            said.add(label)
        label = None
    return "arm", marks


def invocations(lines, name):
    """The args of each invocation of the skill among transcript lines, oldest first: a typed command is a user entry
    naming it, Claude's own a Skill tool call. Only real entries count: not a subagent's sidechain, not the
    api-request-blob copies some versions write, not text that merely quotes a command."""
    command = re.compile(r"<command-name>/?(?:[\w.-]+:)?%s</command-name>" % re.escape(name))
    needle = name.encode()
    for line in lines:
        if needle not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        kind = entry.get("type")
        if entry.get("isSidechain") or kind not in ("user", "assistant"):
            continue
        content = (entry.get("message") or {}).get("content")
        parts = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
        for part in parts:
            if not isinstance(part, dict):
                continue
            if kind == "user" and part.get("type") == "text" and command.search(part.get("text") or ""):
                args = re.search(r"<command-args>(.*?)</command-args>", part["text"], re.S)
                yield args.group(1) if args else ""
            elif kind == "assistant" and part.get("type") == "tool_use" and part.get("name") == "Skill":
                given = part.get("input") or {}
                if str(given.get("skill", "")).split(":")[-1] == name:
                    yield given.get("args") or ""


def newest_reply(lines):
    """The newest real reply among transcript lines, (uuid, time): a main-chain assistant entry that Claude Code didn't
    write itself (its usage-limit and error notices come from the model "<synthetic>")."""
    for line in reversed(lines):
        if b'"assistant"' not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if (entry.get("type") == "assistant" and not entry.get("isSidechain")
                and (entry.get("message") or {}).get("model") != "<synthetic>"):
            return entry.get("uuid"), epoch(entry["timestamp"]) if entry.get("timestamp") else time.time()
    return None


def tail(path, size=1 << 18):
    """The transcript's last complete lines."""
    try:
        with open(path, "rb") as f:
            end = f.seek(0, 2)
            f.seek(max(0, end - size))
            lines = f.read().split(b"\n")
    except (OSError, TypeError):
        return []
    return lines[1:] if end > size else lines


def scan(state, path, name):
    """Brings a session's guard up to date with its transcript: reads what was added since the last look; the newest
    invocation sets the marks, the newest reply's time is kept."""
    try:
        size = os.path.getsize(path)
    except (OSError, TypeError):
        return
    start = state.get("offset", 0) if state.get("transcript") == path else 0
    if start > size:
        start = 0
    first = start == 0
    if first:
        start = max(0, size - FIRST_LOOK)
    with open(path, "rb") as f:
        f.seek(start)
        chunk = f.read(size - start)
    end = chunk.rfind(b"\n") + 1  # complete lines only: one being written is read next time
    lines = chunk[:end].split(b"\n")
    if first and start:
        lines = lines[1:]
    state.update(transcript=path, offset=start + end)
    for args in invocations(lines, name):
        kind, marks = parse(args)
        if kind == "arm":
            state.update(marks=marks, armed_at=time.time(), noticed={}, told=False)
        elif kind == "stop":
            state.update(marks=None, until=None)
    reply = newest_reply(lines)
    if reply:
        state["reply"] = reply[1]


def wake_time(hits):
    return max(h[3] for h in hits) + MARGIN


def describe(hits, now):
    return "; ".join("the %s usage is %.0f%% (mark %.0f%%, resets %s)" % (WINDOWS[n][1], pct, m, clock(reset, now))
                     for n, pct, m, reset in hits)


def sentence(text):
    return text[:1].upper() + text[1:]


def blind_reason(state, live):
    """Why this session can't see its usage, once it has worked a while armed; None while it can."""
    armed, reply = state.get("armed_at"), state.get("reply")
    if not armed or not reply or reply - armed < GRACE:
        return None
    if live and reply - live["fetched_at"] <= STALE:
        return None
    if live:
        why = "the newest usage reading is %s older than this session's last reply" % span(reply - live["fetched_at"])
    elif load(live_path()):
        why = "the newest usage reading is another account's"
    else:
        why = "there is no usage reading yet"
    return ("[quota-guard] %s: this session doesn't seem to run the status line (the desktop app and claude -p don't), "
            "so the guard can't see its usage and won't pause it. Tell the user in one line." % why)


def after_tool(state, data):
    """PostToolUse: the stop notice when a window reaches its mark (once per window and reset), and a word, once, if
    the session has no reading."""
    marks = state.get("marks")
    if not marks or data.get("agent_id"):
        return None
    now, live, notes = time.time(), reading(), []
    blind = blind_reason(state, live)
    if blind and not state.get("told"):
        state["told"] = True
        notes.append(blind)
    noticed = state.setdefault("noticed", {})
    hits = [h for h in over(live, marks, now) if noticed.get(h[0]) != h[3]]
    if hits:
        noticed.update((h[0], h[3]) for h in hits)
        until = wake_time(hits)
        notes.append("[quota-guard] %s. Bring the work to a safe stopping point now: finish or checkpoint the step at "
                     "hand, note what comes next, and end the turn. Don't wait or sleep yourself: when the turn ends, "
                     "quota-guard waits for the reset and wakes this session at %s (in %s)."
                     % (sentence(describe(hits, now)), clock(until, now), span(until - now)))
    if not notes:
        return None
    out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n\n".join(notes)}}
    if hits:
        out["systemMessage"] = "quota-guard: %s; pausing until %s" % (describe(hits, now), clock(until, now))
    return out


def on_pause(state, hits, data, until):
    """QUOTA_GUARD_ON_PAUSE, once a pause: the work due while the session waits (a job queue, a notice), started
    without a window in the session's folder, with the windows and the wake time in its environment."""
    command = os.environ.get("QUOTA_GUARD_ON_PAUSE")
    key = " ".join("%s@%d" % (h[0], h[3]) for h in hits)
    if not command or state.get("ran") == key:
        return
    state["ran"] = key
    import subprocess
    env = dict(os.environ, QUOTA_GUARD_WINDOWS=" ".join(h[0] for h in hits), QUOTA_GUARD_UNTIL=iso(until))
    apart = {"creationflags": 0x08000000 | 0x00000200} if os.name == "nt" else {"start_new_session": True}
    subprocess.Popen(command, shell=True, cwd=data.get("cwd") or None, env=env, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **apart)


def pause(state, data, path):
    """Stop, in the background: if the turn ended at a mark, start QUOTA_GUARD_ON_PAUSE, wait for the reset and wake
    the session. A newer Stop, a disarm, the session's end or a new reply (the user wrote, a heartbeat came) ends the
    wait quietly: the next Stop decides afresh."""
    marks, hits = state.get("marks"), []
    if marks:
        time.sleep(SETTLE)
        hits = over(reading(), marks, time.time())
    if not hits:
        state["until"] = None
        save(path, state)
        return 0
    until, me = wake_time(hits), os.getpid()
    state.update(waiter=me, until=until)
    on_pause(state, hits, data, until)
    save(path, state)
    transcript = data.get("transcript_path")
    seen = newest_reply(tail(transcript))
    while True:
        current = load(path)
        if current is None:
            if not os.path.exists(path):
                return 0
        elif current.get("waiter") != me or not current.get("marks") or newest_reply(tail(transcript)) != seen:
            return 0
        elif time.time() >= until:
            break
        time.sleep(max(0.05, min(TICK, until - time.time())))  # (None: caught mid-replace, read again)
    current["until"] = None
    save(path, current)
    names = " and ".join(WINDOWS[h[0]][1] for h in hits)
    was = ", ".join("%s %.0f%% (mark %.0f%%)" % (WINDOWS[h[0]][0], h[1], h[2]) for h in hits)
    # (Claude Code puts the hook's rewakeMessage, "[quota-guard]", in front of this.)
    sys.stderr.write("The %s window%s reset (this session paused at %s). Go on with the work where it stopped; if "
                     "nothing was left to do, say so in one line.\n" % (names, " has" if len(hits) == 1 else "s have", was))
    return 2


def hook():
    try:
        data = json.loads(sys.stdin.buffer.read() or b"{}")
    except ValueError:
        return 0
    session, event = data.get("session_id"), data.get("hook_event_name")
    if not session:
        return 0
    path = state_path(session)
    if event == "SessionEnd":
        try:
            os.remove(path)
        except OSError:
            pass
        return 0
    state = load(path) or {}
    scan(state, data.get("transcript_path"), skill_name())
    if event == "Stop":
        return pause(state, data, path)
    out = after_tool(state, data) if event == "PostToolUse" else None
    save(path, state)
    if out:
        print(json.dumps(out))
    return 0


def statusline():
    try:
        data = json.loads(sys.stdin.buffer.read() or b"{}")
    except ValueError:
        data = {}
    limits, new = data.get("rate_limits") or {}, {}
    for name in WINDOWS:
        part = limits.get(name) or {}
        if part.get("used_percentage") is not None:
            new[name] = {"utilization": float(part["used_percentage"]),
                         "resets_at": iso(part["resets_at"]) if part.get("resets_at") else None}
    live = record(new, data.get("session_id")) if new else reading()
    now, parts = time.time(), []
    for name, pct, reset in windows(live, now):
        parts.append("%s %.0f%%%s" % (WINDOWS[name][0], pct, " (%s)" % clock(reset, now) if reset and reset > now else ""))
    used = (data.get("context_window") or {}).get("used_percentage")
    if used is not None:
        parts.append("ctx %.0f%%" % float(used))
    state = load(state_path(data["session_id"])) if data.get("session_id") else None
    marks = (state or {}).get("marks")
    if marks:
        parts.append("paused to %s" % clock(state["until"], now) if state.get("until") else
                     "guard " + "/".join("-" if marks.get(n) is None else "%.0f" % marks[n] for n in ("five_hour", "seven_day")))
    print(" | ".join(parts))


def find_transcript(session):
    import glob
    found = glob.glob(os.path.join(glob.escape(config_dir()), "projects", "*", session + ".jsonl"))
    return found[0] if found else None


def status():
    """This account's usage, then the guard of the session this runs in (CLAUDE_CODE_SESSION_ID)."""
    sys.stdout.reconfigure(errors="replace")
    now, live = time.time(), load(live_path())
    if not live:
        print("no usage reading yet (%s): the status line writes one after each response once its command is "
              "quota.py statusline" % live_path())
    elif live.get("account") != account():
        print("the newest usage reading is another account's (%s..., this is %s...): no terminal session of this "
              "account has written one" % (str(live.get("account"))[:8], str(account())[:8]))
    else:
        for name, pct, reset in windows(live, now):
            when = "" if reset is None else "  reset" if reset <= now else "  resets %s (in %s)" % (clock(reset, now), span(reset - now))
            print("%-5s %3.0f%%%s" % (WINDOWS[name][0], pct, when))
        print("read %s ago" % span(now - live["fetched_at"]))
    session = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not session:
        return
    state = load(state_path(session)) or {}
    scan(state, state.get("transcript") or find_transcript(session), skill_name())
    marks = state.get("marks")
    if not marks:
        print("guard: off in this session")
        return
    shown = ["%s %s" % (WINDOWS[n][0], "off" if m is None else "%.0f%%" % m) for n, m in marks.items()
             if m is not None or n != "spend_limit"]
    print("guard: " + ", ".join(shown) + ("; paused until %s" % clock(state["until"], now) if state.get("until") else ""))


def ours(line):
    return "quota.py" in (line or {}).get("command", "") and "statusline" in (line or {}).get("command", "")


def write_settings(path, settings):
    save(path, settings, indent=2, ensure_ascii=False)


def install(replace):
    """Copies the skill into the skills folder (unless it runs from there already), pins this Python in the copy's
    hooks, and makes `quota.py statusline` the statusLine of settings.json. A status line set there before stays
    unless --replace; then it is saved, and uninstall puts it back."""
    import shutil
    target = os.path.join(config_dir(), "skills", skill_name())
    if os.path.normcase(os.path.realpath(target)) != os.path.normcase(os.path.realpath(SKILL_DIR)):
        shutil.copytree(SKILL_DIR, target, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests"))
    def quote(path):
        path = path.replace("\\", "/")
        return '"%s"' % path if " " in path else path

    run = "%s -I -S %s" % (quote(sys.executable), quote(os.path.join(target, "scripts", "quota.py")))
    skill_md = os.path.join(target, "SKILL.md")
    with open(skill_md, encoding="utf-8", newline="") as f:
        text = f.read()
    # (Each hook's command becomes a single-quoted YAML scalar: a value that began with a quoted path would not parse.)
    pinned = re.sub(r"(?m)^([ \t]*command:[ \t]*).*quota\.py\"?[ \t]+hook'?[ \t]*(\r?)$",
                    lambda m: "%s'%s hook'%s" % (m.group(1), run.replace("'", "''"), m.group(2)), text)
    if pinned != text:
        with open(skill_md, "w", encoding="utf-8", newline="") as f:
            f.write(pinned)
    settings_path = os.path.join(config_dir(), "settings.json")
    settings = load(settings_path) or {}
    current, saved = settings.get("statusLine"), os.path.join(config_dir(), "quota-guard", "statusline-before.json")
    if current and not ours(current):
        if not replace:
            print("settings.json already has a status line (%s). Run install --replace to put quota-guard's in its place "
                  "(yours is saved; uninstall puts it back), or have yours also pipe its input to: %s statusline"
                  % (current.get("command"), run))
            return 1
        if not os.path.exists(saved):
            save(saved, current)
    settings["statusLine"] = {"type": "command", "command": run + " statusline"}
    write_settings(settings_path, settings)
    print("installed %s\n  hooks and status line run: %s" % (target, run))
    return 0


def uninstall():
    """Puts back the status line install replaced, or removes quota-guard's; the skill's files stay."""
    settings_path = os.path.join(config_dir(), "settings.json")
    settings = load(settings_path) or {}
    saved = os.path.join(config_dir(), "quota-guard", "statusline-before.json")
    if not ours(settings.get("statusLine")):
        print("the status line isn't quota-guard's: left as it is")
        return 0
    before = load(saved)
    if before:
        settings["statusLine"] = before
        os.remove(saved)
    else:
        settings.pop("statusLine")
    write_settings(settings_path, settings)
    print("status line %s" % ("restored: %s" % before.get("command") if before else "removed"))
    return 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "statusline":
        statusline()
    elif command == "hook":
        return hook()
    elif command == "status":
        status()
    elif command == "install":
        return install("--replace" in sys.argv[2:])
    elif command == "uninstall":
        return uninstall()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
