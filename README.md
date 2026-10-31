# quotabeat

让 Claude Code 的长时间、无人值守的工作留在套餐用量之内，并让提示缓存不失效。一个 Claude Code skill：一个 bash 脚本加一份 SKILL.md，不连网，不用 Python。

## 它做三件事

1. **到线停手，留出备用。** 5 小时窗口用到 87%、一周用到 97%（可调），Claude 会在下一次工具调用后收到提醒：把手上这一步做完或存档、记下下一步、结束这一轮。线以上的部分是备用：收尾、心跳、急用。过了备用的一半还没停，会再提醒一次。
2. **重置后自己醒来。** 停在线上的那一轮结束时，后台的 Stop 钩子等到窗口重置（再过一分钟），把会话叫醒接着做。
3. **心跳保温（原 cachebeat）。** 会话闲着 50 分钟，钩子叫醒它，Claude 只回一个 `.`，1 小时的提示缓存就续上了，下一次真正的工作按缓存价读上下文，而不是全价重读。
   - 连续心跳最多 19 次（约 16 小时）就停：读一次缓存约 0.1 倍上下文的价，冷读（重写缓存）约 2 倍，19 次心跳就抵得上一次冷读；不知道还要闲多久时，这样花费最多是最优的两倍（租还是买的问题）。
   - 停手期间知道要停多久：短于约 16 小时（5 小时窗口）就一路心跳到醒来；更长的（一周的线）不心跳，醒来时冷读一次，比心跳到底便宜。

## 用量从哪里来（不连网）

- **终端里的会话**：Claude Code 每次回应都带着账号的用量（`rate_limits`），并交给状态栏命令。`quotabeat.sh statusline` 把它记在 `~/.claude/quotabeat/usage-<账号>`，每个账号一份（桌面 App 可以登录与终端不同的账号）。同一窗口里取较大的读数（闲着的会话拿旧数据重跑，压不低它），较新的窗口取代旧的。
- **桌面 App 的会话**：桌面 App 不跑状态栏（实测）。钩子在需要时让 Claude 调一次 App 自带的用量工具 `get_usage`，自己读出数字记下来，并把那份约 600 token 的报告换成一行（`Usage (recorded by quotabeat): 5h 86% (04:20), 7d 12% (Mon 15:00).`）。多久查一次看离线还有多远：还差 N 个百分点，就隔 N/2 分钟再查，最少 5 分钟、最多 1 小时。

## 安装

```bash
bash install.sh             # 复制到 ~/.claude/skills/quotabeat，并把状态栏设为 quotabeat
bash install.sh --replace   # 已有别的状态栏时，用 quotabeat 的替换它（原来的会保存）
bash install.sh uninstall   # 状态栏恢复原样
```

已有自己的状态栏又不想替换：让它把收到的输入也交给 `bash ~/.claude/skills/quotabeat/quotabeat.sh statusline` 一份即可。需要 bash 和 coreutils（Windows 上是 Git Bash，Claude Code 本来就用它）。

## 使用

```
/quotabeat                 启用：5 小时 87%、一周 97%，闲置 50 分钟心跳
/quotabeat 85 95           两条线
/quotabeat week=off        只看 5 小时窗口（5h=off 同理）
/quotabeat beat=30         心跳间隔（5 到 55 分钟；beat=off 不心跳）
/quotabeat stop            这个会话里关掉
```

Claude 也可以自己启用（长时间无人值守的工作开始前）。启用后不用开任何东西：没有后台监视进程，也不轮询。状态栏显示 `5h 6% (04:00) | 7d 94% (Mon 09:00) | ctx 64% | guard 87/97`，停手时显示 `paused to 04:01`。

## 会不会多耗额度

- 钩子都是本机进程，不发请求，不耗额度。到线检查在每次工具调用后于后台进行，不拖慢工具调用。
- 启用时 SKILL.md 正文（约 600 token）进入上下文；每条提醒几十 token。
- 心跳：每次约是读一次缓存的上下文（0.1 倍），连续最多 19 次。
- 叫醒：每次重置后一次请求，和以前起一个等待进程、等它结束来叫醒是一样的。
- 桌面 App：每次用量检查是一次工具调用（离线越远越少）。

## 怎么做的

| 钩子 | 时机 | 做什么 |
| --- | --- | --- |
| `!` 指令（SKILL.md） | 调用 `/quotabeat` 时 | `quotabeat.sh arm`：把这个会话的线和心跳写进 `~/.claude/quotabeat/<会话>`，回一行现状给 Claude |
| PostToolUse（后台，asyncRewake） | 每次工具调用后 | 读本账号的用量，到线就以退出码 2 叫醒 Claude 并附上提醒；桌面 App 里按需要求查一次用量 |
| PostToolUse（`get_usage`） | 桌面 App 查用量后 | 记下用量，把报告换成一行 |
| Stop（后台，asyncRewake） | 每一轮结束时 | 在线上：等到重置再叫醒；闲着：到时候心跳。新的一轮、用户发话、`stop`、会话结束都会让等待中的它安静退出 |
| UserPromptSubmit、SessionEnd | | 记下会话活跃；会话结束时清掉状态 |

## 限制

- 钩子跟着会话注册：Claude Code 进程重启后要重新 `/quotabeat`。
- `claude -p` 没有状态栏也没有 `get_usage`，看不到用量。
- 一轮里如果直接用到 100%，那一轮以错误结束、不经过 Stop 钩子：这正是要在线以下留备用的原因。Claude Code 的设置 `autoContinueAtUsageLimit` 是它自带的兜底。
- 提示缓存只活 5 分钟的会话，心跳留不住它：启用时会自动关掉心跳。

## 测试

```bash
bash tests/run.sh
```

每个测试像 Claude Code 那样运行脚本（输入 JSON，读回退出码和输出），用自己的临时配置目录；`QUOTABEAT_UNIT=1` 把一分钟缩成一秒。排查问题时，建一个空文件 `~/.claude/quotabeat/debug`，钩子会把收到的输入记到旁边的 `debug.log`。

## 来历

心跳的做法来自 [cachebeat](https://github.com/ARahim3/cachebeat)（MIT）；额度部分来自本机的额度监视脚本。被取代的版本在 `archive/`。
