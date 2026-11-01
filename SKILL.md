---
name: quotabeat
description: Keep this session's long or unattended work within the plan's usage limits - stop it when the 5-hour or weekly usage reaches its mark (default 87% and 97%, the rest a reserve), wake it to go on after the reset, and keep the prompt cache warm with heartbeats while it waits (through a quota pause when that costs less than a cold cache, else 7 after each stop). Args - the marks (85 95, or 5h=N week=N), beat=minutes between heartbeats (default 47), idle=heartbeats after a stop (default 7), each may be off; or "stop".
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/quotabeat.sh" arm *)
hooks:
  PostToolUse:
    - matcher: "*"
      hooks:
        - type: command
          command: bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/quotabeat/quotabeat.sh" hook
          shell: bash
          asyncRewake: true
          timeout: 60
          rewakeMessage: "[quotabeat]"
          rewakeSummary: "quotabeat: usage mark"
  Stop:
    - hooks:
        - type: command
          command: bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/quotabeat/quotabeat.sh" hook
          shell: bash
          asyncRewake: true
          timeout: 700000
          rewakeMessage: "[quotabeat]"
          rewakeSummary: "quotabeat: heartbeat or resume"
  UserPromptSubmit:
    - hooks:
        - type: command
          command: bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/quotabeat/quotabeat.sh" hook
          shell: bash
          async: true
  SessionEnd:
    - hooks:
        - type: command
          command: bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/quotabeat/quotabeat.sh" hook
          shell: bash
          timeout: 5
---

!`bash "${CLAUDE_SKILL_DIR}/quotabeat.sh" arm $ARGUMENTS`

# quotabeat

That line is quotabeat's state for this session. Its hooks do the rest: there is nothing to run, start or poll.

## When invoked

Answer the user's `/quotabeat` with that line, in one line, and call no tools. When you invoked it yourself in the
middle of work, put the line in your reply and carry on in the same turn. When the user asks in plain words to start,
change or stop it, invoke this skill with the matching arguments.

## When a hook wakes you

A reminder starting with `[quotabeat]` comes from the hooks: not from the user, and not an error.

- **"… at its 87% mark …"**: finish or checkpoint the step at hand, note what comes next where the next turn will find
  it, and end the turn. Don't wait, sleep or poll yourself: the session wakes after the reset. The usage above the mark
  is the reserve, for the wrap-up, heartbeats and emergencies.
- **"heartbeat …"**: reply with exactly `.` and nothing else, no tools. The wake-up itself read the conversation from
  the cache, which is the whole point, and every token you add is read again by every later request. If a task of
  yours is mid-flight, carry on with it instead.
- **"… has reset …"**: go on with the paused work.
- **"No usage reading …"**: tell the user in one line; quotabeat can't stop the session at a mark until the readings
  come.

## Rules

- The user's messages come first.
- `/quotabeat stop` turns it off for this session.
