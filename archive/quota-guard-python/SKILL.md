---
name: quota-guard
description: Watch the Claude plan's 5-hour and weekly usage limits offline (from the usage every API response already carries, via the status line) and guard long or unattended work with them - at a mark in either window Claude stops at a safe point, and the session wakes by itself once the window resets. Use when work will run long or unattended (training runs, overnight jobs, batches, the user stepping away) and could hit a usage limit; when the user asks how much of the 5-hour or weekly quota is left or when it resets; or when they want work to stop at some percentage of either limit. Args - the 5-hour mark and the weekly mark in percent (default 87 95; also 5h=80, week=90, week=off), "status", or "stop".
hooks:
  PostToolUse:
    - matcher: "*"
      hooks:
        - type: command
          command: python3 -I -S "$HOME/.claude/skills/quota-guard/scripts/quota.py" hook
          timeout: 10
          shell: bash
  Stop:
    - hooks:
        - type: command
          command: python3 -I -S "$HOME/.claude/skills/quota-guard/scripts/quota.py" hook
          asyncRewake: true
          timeout: 700000
          rewakeMessage: "[quota-guard]"
          rewakeSummary: "quota-guard: the usage window reset, resuming"
          shell: bash
  SessionEnd:
    - hooks:
        - type: command
          command: python3 -I -S "$HOME/.claude/skills/quota-guard/scripts/quota.py" hook
          timeout: 5
          shell: bash
---

# quota-guard: usage limits read offline, a clean pause, an automatic wake-up

Claude Code receives the account's 5-hour and weekly usage with every API response and hands it to the status line
command; `scripts/quota.py statusline` (the status line `install` sets up) writes it to `quota_live.json` in the config
folder. This skill's hooks read that file and nothing else: nothing asks a server, nothing polls.

## When invoked

`/quota-guard [5h mark] [weekly mark]` arms the guard for this session, `/quota-guard stop` disarms it, and
`/quota-guard status` only reports. Marks are percentages: bare numbers are the 5-hour mark, then the weekly one
(defaults **87** and **95**); `5h=80`, `week=90`, `week=off` and, behind a gateway with a spend limit, `spend=90` work
too. The hooks read the newest invocation from the transcript themselves, so there is nothing to start: no watcher,
no background task.

Then run `scripts/quota.py status` from this skill's base directory (Python 3: `python3`, or `python` on Windows) and
reply in one line: the marks in force and the usage now, with the reset times. If it says the reading is another
account's or missing, add that this session can't see its usage (see "Readings").

If you arm it yourself in the middle of work (do, before a long or unattended stretch the user wants watched), put
that line in your reply and carry on in the same turn.

## While armed

- **"[quota-guard] The 5-hour usage is 88% (mark 87%, ...)"** beside a tool result: bring the work to a safe stopping
  point (finish or checkpoint the step at hand, write down what comes next where the next turn will find it) and end
  the turn. Don't start a wait, a sleep or a polling loop yourself: when the turn ends, the Stop hook waits for the
  reset and wakes the session. Don't push on for one more step either: the reading lags a response, and what is left
  above the mark is for the wrap-up, cache heartbeats and the user's own use.
- **"[quota-guard] The 5-hour window has reset ..."**, a reminder that wakes the session: pick the paused work up
  where it stopped. If nothing was pending, say so in one line.
- **"[quota-guard] ... doesn't seem to run the status line ..."**: tell the user in one line; the guard can't pause
  this session.
- The user comes first: if they write during a pause, answer them. The guard checks again when that turn ends.
- A long pause (a weekly window, more than about half a day): if a cache keepalive such as cachebeat is armed, stop
  it. Over that long its heartbeats cost more than one cold re-read, and they spend the very quota the pause saves.

## Readings

Usage is per account, and each reading is tagged with the account that wrote it. Only sessions that run the status
line write readings: terminal sessions (the CLI, an IDE's terminal). The desktop app's sessions and `claude -p` runs
don't, so there the guard sees usage only while a terminal session of the same account is working, and the desktop
app may be signed in to a different account from the terminal. Where the environment has a usage tool of its own
(the desktop app does), answer questions about usage with it.

## Setup, once per machine

`python3 scripts/quota.py install` copies the skill into the skills folder (`~/.claude/skills/quota-guard`, or under
`CLAUDE_CONFIG_DIR`), pins the Python that ran it in the hooks, and makes `quota.py statusline` the status line, which
shows `5h 2% (04:00) | 7d 94% (Mon 09:00) | ctx 12% | guard 87/95`. A status line set before stays unless
`--replace`; then it is saved, and `uninstall` puts it back. Run `install` again after changing the skill's source.

`QUOTA_GUARD_ON_PAUSE`, set in a settings file's `env`: a shell command started once per pause in the session's
folder, with `QUOTA_GUARD_WINDOWS` and `QUOTA_GUARD_UNTIL` in its environment; a job queue there lets the machine work
through the wait.
