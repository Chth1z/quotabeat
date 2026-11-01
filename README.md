# quotabeat

一个 Claude Code skill：让一个会话里长时间、无人值守的工作守在套餐用量之内，等待时让提示缓存不失效。一个 bash 脚本加一份 SKILL.md，只用钩子，不联网，不用 Python，读用量不多发任何请求。

## 它做什么

启用后绑定当前会话：

1. **到线停手，留出备用。** 5 小时窗口用到 87%、一周用到 97%（可调）时，Claude 在下一次工具调用后收到提醒：做完或存档手上这一步，记下下一步，结束这一轮。线以上是备用，留给收尾、心跳和急用。过了备用的一半还没停，会再提醒一次。
2. **重置后接着做。** 被提醒停下的那一轮结束后，Stop 钩子等到窗口重置（再过一分钟），叫醒会话继续。
3. **等待时心跳保温（原 cachebeat）。** 每 47 分钟一次心跳：钩子叫醒会话，Claude 只回一个 `.`。这次请求按缓存价读一遍上下文，1 小时的提示缓存就续上了。
   - **停在线上**（知道要等到几点）：心跳照样每 47 分钟一次。只有最后一段（最后一次心跳到叫醒；一次都不用跳时就是停下到叫醒）不超过 53 分钟就够了，因为叫醒时缓存还热（缓存的 1 小时留 7 分钟余量）。所以次数 = ⌈（到叫醒的分钟数 − 53）÷ 47⌉：等 50 分钟不跳，等 100 分钟跳 1 次，等 5 小时跳 6 次。少于 19 次就一路跳到重置，否则一次都不跳，醒来时冷读一次。账是这样算的：一次心跳读缓存，约 0.1 倍上下文的价；缓存冷了要重写，约 2 倍，比热读多 1.9 倍。所以不会出现「跳了一阵、最后还是冷掉」的双重花费。
   - **其他时候，只要停下**：再跳 7 次（`idle=N`），也就是停下后 7×47 分钟内。第 k 次在停下后 k×47 分钟，按时间算，不靠数 Claude 的回复。你发话或 Claude 用了工具，就从新的停下重新算。
   - **电脑待机**：心跳只在缓存肯定还热时发出，也就是距上次读缓存不超过 53 分钟。睡过了就不跳，因为补跳只是付钱重写缓存。Windows（Git Bash）和 macOS 的 `sleep` 在待机时不走表，所以计时器每次最多睡 1 分钟就看一次时钟，醒来后一分钟内就会按实际时间判断。

## 用量从哪里来（不联网，不多发请求）

每个 API 响应的头里都带着账号的用量：`anthropic-ratelimit-unified-5h-utilization`（0.35 就是 35%）和 `-5h-reset`（重置时刻），一周的是 `7d`。设了下面三个环境变量，Claude Code 会把每个响应的头记进它的 debug 日志：

- **终端里的会话**：`~/.claude/debug/<会话>.txt`，每个响应一行。
- **桌面 App 的会话**：`~/.claude/debug/sdk-*.txt`，每个头一行，同一个响应的各行有时次序会乱。

quotabeat 在每次工具调用后和每一轮结束时读日志的尾部，每个字段取最后出现的值，所以次序乱了也不要紧。终端会话只读自己的那份；桌面会话只认组织（org）和自己相同的日志（环境变量 `CLAUDE_CODE_ORGANIZATION_UUID`），所以终端和桌面登录不同账号也不会混在一起。读用量不调工具、不发请求，也不需要状态栏。

## 安装

1. 把 `SKILL.md` 和 `quotabeat.sh` 放进 `~/.claude/skills/quotabeat/`：

   ```bash
   mkdir -p ~/.claude/skills/quotabeat && cp SKILL.md quotabeat.sh ~/.claude/skills/quotabeat/
   ```

2. 设三个用户环境变量。Windows（PowerShell）：

   ```powershell
   'ANTHROPIC_LOG=debug','DEBUG_SDK=1','DEBUG_CLAUDE_AGENT_SDK=1' | % { $k,$v = $_ -split '='; [Environment]::SetEnvironmentVariable($k,$v,'User') }
   ```

   macOS / Linux 写进 shell 的启动文件（`export ANTHROPIC_LOG=debug DEBUG_SDK=1 DEBUG_CLAUDE_AGENT_SDK=1`）。

3. 桌面 App 完全退出再打开（连系统托盘图标一起退），终端开新窗口：已经在跑的程序拿不到新变量。

需要 bash 和 coreutils（Windows 上是 Git Bash，Claude Code 本来就用它）。

## 使用

```
/quotabeat              启用：5 小时 87%、一周 97%，每 47 分钟一次心跳，停下后 7 次
/quotabeat 85 95        两条线（也可以写 5h=85 week=95）
/quotabeat week=off     只看 5 小时窗口（5h=off 同理）
/quotabeat beat=30      心跳间隔，5 到 53 分钟（beat=off 不心跳）
/quotabeat idle=3       停下后跳几次（idle=0 只在停线等待时心跳）
/quotabeat stop         这个会话里关掉
```

Claude 也可以自己启用（长时间无人值守的工作开始前）。启用后不用开任何东西：没有监视进程，用量随响应写进日志。启用时回的一行里有当前用量；读不到时会直说原因。

## 额度花在哪里

- 钩子都是本机进程，不发请求，不耗额度；读用量也一样。
- 启用时 SKILL.md 正文（约 400 token）进入上下文；描述（约 120 token）在每个会话的技能清单里。每条提醒几十 token。
- 心跳：每次约读一次缓存的上下文（0.1 倍），加上一行提醒和一个 `.`。停在线上只在比冷缓存便宜时跳，其他时候每次停下后最多 7 次。
- 叫醒：每次重置后一次请求。

## 开着这三个变量的代价

- `claude -p` 的输出前面会多一大段 SDK 的请求和响应记录（印在 stdout 上），这种会话也读不到用量。读 `claude -p` 输出的脚本可以加 `-d2e`（`--debug-to-stderr`，把记录改印到 stderr），或临时设 `ANTHROPIC_LOG=warn claude -p ...`。
- debug 日志会变大。Claude Code 默认只清 30 天前的 debug 日志（`cleanupPeriodDays`），期间单文件不按大小轮转；实测桌面的 `sdk-*.txt` 在连续工作时一分钟长了约 60 KB。可以定期删掉一天前的日志（正在用的日志一直在更新，不会被删）：

  ```bash
  find ~/.claude/debug -name '*.txt' -mtime +1 -delete
  ```

- 桌面 App 里，这段记录是从 Claude Code 子进程的 stdout 出来的（那本来是传 JSON 的通道）；App 把非 JSON 的行记进日志后照常工作（桌面内置 Claude Code 2.1.309 实测）。

## 怎么做的

| 钩子 | 时机 | 做什么 |
| --- | --- | --- |
| `!` 指令（SKILL.md） | 调用 `/quotabeat` 时 | `quotabeat.sh arm`：把这个会话的线和心跳写进 `~/.claude/quotabeat/<会话>`，回一行现状给 Claude |
| PostToolUse（后台，asyncRewake） | 每次工具调用后 | 从 debug 日志读用量，到线就以退出码 2 叫醒 Claude 并附上提醒；记下这一轮是真正的工作 |
| Stop（后台，asyncRewake） | 每一轮结束时 | 计时器：被提醒停下的会话等到重置再叫醒，途中按上面的账心跳；其他时候在停下后跳 IDLE 次。更新的一轮结束、你发话、`stop`、会话结束，都会让等待中的计时器醒来时安静退出 |
| UserPromptSubmit（后台） | 你发话时 | 等待中的计时器让位 |
| SessionEnd | 会话结束 | 清掉状态 |

## 限制

- 钩子跟着 Claude Code 进程注册：进程重启后要重新 `/quotabeat`。桌面 App 也会重启进程（例如设置或说明文件改动后，下一条消息到达时）。
- 桌面 App 实测（2026-11-01）：闲置 5 分钟后，Stop 钩子的心跳把会话叫醒了；更长时间的闲置还没测过。桌面 App 会把叫醒当成一条 prompt 送进来（触发 UserPromptSubmit），计时器发心跳时先做记号，所以这条不算你发话。这个修正也在桌面 App 实测过：心跳那一轮之后起点没有移动，跳完设定的次数就停了。
- 只读 5 小时和一周两个窗口。
- 一轮里直接用到 100%，那一轮以错误结束、不经过 Stop 钩子：所以要在线以下留备用。
- 提示缓存只活 5 分钟的会话，心跳留不住它：启用时自动关掉心跳。

## 测试

```bash
bash tests/run.sh
```

每个测试像 Claude Code 那样运行脚本（输入 JSON，读回退出码和输出），用自己的临时配置目录，按 Claude Code 的格式写 debug 日志；`QUOTABEAT_UNIT=1` 把一分钟缩成一秒。排查问题时，建一个空文件 `~/.claude/quotabeat/debug`，钩子会把每次做了什么记到旁边的 `debug.log`。

## 来历

心跳的做法来自 [cachebeat](https://github.com/ARahim3/cachebeat)（MIT）；从响应头日志读用量的办法来自用户的 `quota_headers.sh`。被取代的版本在 `archive/`。
