---
name: quotabeat
description: Keep long or unattended Claude Code work inside the plan's usage limits and its prompt cache warm - stop at a safe point when the 5-hour or weekly usage reaches its mark (keeping a reserve), send heartbeats while the session idles or waits so the cache doesn't lapse, and wake the session to go on once the window resets. Use before unattended stretches (training runs, batches, overnight jobs, waiting on background tasks), when the user steps away, or when they want work to stop at some percentage of the 5-hour or weekly limit. Args - the 5-hour and weekly marks in percent (default 87 97; also 5h=N, week=N, beat=minutes, any of them off), or "stop".
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
    - matcher: "mcp__ccd_session_mgmt__get_usage"
      hooks:
        - type: command
          command: bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/quotabeat/quotabeat.sh" usage
          shell: bash
          timeout: 10
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

That line is quotabeat's state for this session; its hooks do the rest, so there is nothing to start or poll.

- Answer the user's own `/quotabeat` with that line, in one line. When you invoked it yourself in the middle of
  work, put the line in your reply and keep working in the same turn.
- **"[quotabeat] The 5-hour usage is 88%, at its 87% mark …"**: finish or checkpoint the step at hand, note what
  comes next where the next turn will find it, and end the turn. Don't wait, sleep or poll yourself: the session
  wakes by itself after the reset. What is left above the mark is the reserve: for the wrap-up, heartbeats and
  emergencies. If something wakes you during the pause (a background task ends), deal with it briefly and end the
  turn again.
- **"[quotabeat] … heartbeat …"**: reply with exactly `.` and nothing else (it only refreshes the prompt cache),
  unless a task of yours is mid-flight; then carry on with it.
- **"[quotabeat] The … window has reset …"**: go on with the paused work.
- **"[quotabeat] Usage check due …"** (the desktop app, which runs no status line): call the usage tool it names.
- The user's own messages come first. `/quotabeat stop` turns it off for this session.
