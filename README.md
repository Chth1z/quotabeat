# quotabeat 🫀

**让 Claude Code 的长任务守在套餐额度之内：到线自动停手存档，窗口重置自动唤醒续跑，等待时用缓存心跳防止上下文过期。**

一个轻量的 Claude Code Skill，把**套餐额度守卫**和**提示缓存保温（cachebeat）**合二为一。整个实现只有一个 `SKILL.md` 和一个 `quotabeat.sh`：纯钩子驱动、不联网、不用 Python，读用量不多发任何一次请求，同时支持 **CLI 终端**与 **Claude Desktop 桌面端**。

## 为什么需要它

在 Claude Pro / Max / Team 套餐下跑长会话或无人值守任务，最容易踩中两个坑：

1. **撞上 100% 额度直接断档**：5 小时或一周额度一旦在某轮中途耗尽，请求会直接以 API 错误中断，Claude 连存档收尾的机会都没有，更不会触发 `Stop` 钩子。
2. **离开或等重置超过 1 小时，缓存过期付 20 倍代价**：Claude 每一轮都要重发整段对话历史。1 小时内命中提示缓存（Prompt Cache）只需 **0.1×** 输入价；一旦闲置超过 1 小时 TTL，回来发一句话就要按 **2.0×** 写入价重建整段上下文——在一个 50 万 token 的长会话里，冷启动一次相当于凭空烧掉 100 万 token 的套餐额度。

`/quotabeat` 在当前会话里挂上静默钩子，替你把这两件事管起来：

1. **到线停手，留出备用。** 5 小时窗口用到 **87%**、一周用到 **97%**（均可调）时，Claude 在下一次工具调用后收到提醒：做完或存档手头这一步，记下下一步，结束本轮。线以上是备用额度，留给收尾、心跳和急用；过了备用的一半还没停，会再提醒一次。
2. **重置后自动唤醒接着做。** 被提醒停下的那一轮结束后，`Stop` 钩子自动睡到窗口重置（再留 1 分钟余量），准时叫醒会话继续干活，不用人工盯盘。
3. **等待时心跳保温（继承自 cachebeat）。** 每 **47 分钟**一次心跳：钩子叫醒会话，Claude 只回一个 `.`。这次请求按 `0.1×` 缓存价读一遍上下文，整段历史的 1 小时缓存 TTL 就重新续满了。
   - **停在线上等重置**（知道要等到几点）：只有最后一段（最后一次心跳到叫醒；不跳时就是停下到叫醒）不超过 53 分钟就够了（1 小时缓存留 7 分钟余量）。因此心跳次数 = `⌈（到叫醒的分钟数 − 53）÷ 47⌉`：等 50 分钟不跳，等 100 分钟跳 1 次，等 5 小时跳 6 次。账是这样算的：一次心跳读缓存约 `0.1×` 上下文价，缓存冷了重写约 `2.0×`（比热读多 `1.9×`）。所以**少于 19 次就一路跳到重置，否则一次都不跳**、醒来时冷读一次，绝不花「跳了一阵最后还是冷掉」的双份钱；如果判定不跳，停手提醒里会顺带算出当前上下文 token 数，让 Claude 简短告知你「等待过长不划算跳心跳、当前上下文多大、是否要手动 `/compact`」。
   - **平时闲置停下**：默认再跳 **7 次**（`idle=7`，即停下后 7×47 分钟内）。第 k 次严格在停下后 k×47 分钟触发，按时钟算，不靠数 Claude 的回复。你发话或 Claude 用了工具，就从新的停下重新算。
   - **电脑待机防呆**：心跳只在缓存肯定还热时发出（距上次活跃不超过 53 分钟）。电脑休眠睡过了头就不跳，因为对着冷缓存补跳只是白付一次重写费。由于 Windows（Git Bash）和 macOS 的 `sleep` 在系统待机时不走表，计时器每次最多睡 1 分钟就看一次墙上时钟，电脑醒来后 1 分钟内就能按真实时间判断。

## 安装

1. 把 `SKILL.md` 和 `quotabeat.sh` 放进 `~/.claude/skills/quotabeat/`：

   ```bash
   mkdir -p ~/.claude/skills/quotabeat && cp SKILL.md quotabeat.sh ~/.claude/skills/quotabeat/
   ```

2. 设置三个环境变量（让 Claude Code 把每次 API 响应头写进本地 debug 日志）。

   **Windows（PowerShell）：**

   ```powershell
   'ANTHROPIC_LOG=debug','DEBUG_SDK=1','DEBUG_CLAUDE_AGENT_SDK=1' | % { $k,$v = $_ -split '='; [Environment]::SetEnvironmentVariable($k,$v,'User') }
   ```

   **macOS / Linux（写入 shell 启动文件）：**

   ```bash
   export ANTHROPIC_LOG=debug DEBUG_SDK=1 DEBUG_CLAUDE_AGENT_SDK=1
   ```

3. **重启客户端**：桌面 App 完全退出再打开（连系统托盘图标一起退出），终端开新窗口——已经在跑的进程拿不到新环境变量。

> **环境要求**：`bash` 和 `coreutils`（Windows 上即 Claude Code 自带依赖的 Git Bash）。无需审批权限，钩子在后台静默运行。

## 使用

在会话里直接输入斜杠指令：

```text
/quotabeat              启用：5 小时 87%、一周 97%，每 47 分钟一次心跳，停下后跳 7 次
/quotabeat 85 95        自定义两条停手线（也可以写 5h=85 week=95）
/quotabeat week=off     只看 5 小时窗口（5h=off 同理）
/quotabeat beat=30      心跳间隔，5 到 53 分钟（beat=off 关闭心跳）
/quotabeat idle=3       平时停下后跳几次（idle=0 只在停线等重置时心跳）
/quotabeat stop         在当前会话里关掉
```

你也可以直接用自然语言交代 Claude（比如「帮我跑完这批任务，用 quotabeat 看住额度和缓存」），Claude 会在长任务开始前自己调用它。

启用后会立刻返回一行当前状态与实时额度（例如 `quotabeat: armed 5h=87% week=97% beat=47m idle=7 | now 5h=35% ...`）；如果环境变量未生效或暂时读不到用量，也会当场直说原因。

## 怎么做的

### 1. 用量从哪里来（不联网，不多发请求）

每次 Claude 请求 `/v1/messages`，Anthropic 返回的 HTTP 响应头里都自带当前账号的实时配额：
- `anthropic-ratelimit-unified-5h-utilization`（如 `0.35` 即 `35%`）与 `-5h-reset`（重置时间戳）
- `anthropic-ratelimit-unified-7d-utilization` 与 `-7d-reset`

开启上面三个环境变量后，Claude Code 会把每个响应头落盘到 `~/.claude/debug/`：
- **CLI 终端会话**：写入 `~/.claude/debug/<session-id>.txt`，每个响应一行。
- **桌面 App 会话**：写入 `~/.claude/debug/sdk-*.txt`，每个响应头一行（同一响应内各行顺序可能打乱）。

`quotabeat` 在每次工具调用后和每轮结束时读取日志尾部，每个字段取最后出现的值，不怕乱序。终端会话只读自己的日志；桌面会话通过环境变量 `CLAUDE_CODE_ORGANIZATION_UUID` 校验组织 ID，只认同一账号的响应，即使终端和桌面同时登录不同账号也绝不串台。

### 2. 四个钩子怎么配合

| 钩子 | 时机 | 做什么 |
| --- | --- | --- |
| `!` 指令（`SKILL.md`） | 调用 `/quotabeat` 时 | 执行 `quotabeat.sh arm`：把当前会话的停手线和心跳参数写进 `~/.claude/quotabeat/<会话>`，返回一行现状给 Claude |
| `PostToolUse`（后台，`asyncRewake`） | 每次工具调用后 | 从 debug 日志读用量，到线就以退出码 `2` 叫醒 Claude 并附上停手提醒；记下这一轮是真正的工作 |
| `Stop`（后台，`asyncRewake`） | 每一轮结束时 | 后台计时器：到线停下的会话一路（按划算账单心跳）等到重置再叫醒；平时停下后最多跳 `IDLE` 次。一旦有新一轮结束、你发话、`stop` 或会话关闭，旧计时器会在醒来时安静让位退出 |
| `UserPromptSubmit`（后台） | 你发话时 | 让等待中的旧计时器让位 |
| `SessionEnd` | 会话结束 | 清理状态文件，防止残留计时器打扰新会话 |

## 额度与日志开销

### 额度花在哪里
- **钩子与读用量：0 token。** 全部是本机脚本读本地文件，不发网络请求。
- **启用 Skill：** `SKILL.md` 正文约 400 token 进入上下文；技能列表描述约 120 token；每次触线或唤醒提醒仅几十 token。
- **心跳与唤醒：** 每次心跳按缓存价（`0.1×`）读一遍历史上下文，外加一行提醒和一个 `.` 回复；停在线上只在比冷重建便宜时跳，平时闲置最多跳 7 次。窗口重置后唤醒消耗一次正常请求。

### 开着三个环境变量的副作用与处理
- **`claude -p` 单次命令模式**：stdout 前面会多印出 SDK 的请求/响应调试记录（且 `-p` 模式不写 debug 文件）。如果有脚本解析 `claude -p` 的输出，可以加 `-d2e`（`--debug-to-stderr`）把调试记录改印到 stderr，或临时加前缀 `ANTHROPIC_LOG=warn claude -p ...`。
- **debug 日志体积增长**：Claude Code 默认只清理 30 天前的日志（`cleanupPeriodDays`），单文件不按大小轮转；实测桌面端连续高强度工作时 `sdk-*.txt` 每分钟约增长 60 KB。可以定期删掉一天前的旧日志（正在跑的会话一直在写入，不会被删）：

  ```bash
  find ~/.claude/debug -name '*.txt' -mtime +1 -delete
  ```

- **桌面 App 兼容性**：桌面版里这些调试行从内置 Claude Code 子进程的 stdout 流出，App 会自动把非 JSON 行归入日志并照常工作（内置 Claude Code 2.1.309 / 2.1.312 实测通过）。

## 限制与注意事项

- **进程重启后需重新启用**：Skill 钩子跟着 Claude Code 进程注册，终端重启或 `--resume` 后需再跑一次 `/quotabeat`。桌面 App 在改动设置或说明文件后也可能在下条消息到达时重启子进程。
- **桌面 App 实测（2026-11-01）**：已实测闲置 5 分钟及 47 分钟完整周期，`Stop` 钩子均准时唤醒会话并 100% 命中历史缓存。桌面 App 会把钩子唤醒当成一条用户消息送入（触发 `UserPromptSubmit`），计时器在发心跳前会先落盘记号，因此不会把心跳误判为你发话而重置空闲起点。
- **只管 5 小时和一周两个主窗口**：不跟踪额外按量计费（Extra Usage）池。
- **留足备用线**：如果在单轮重度操作里直接把额度冲到 100%，请求会直接报错中断、不经过 `Stop` 钩子，因此默认留了 87% / 97% 的余量。
- **5 分钟短缓存自动停跳**：非订阅账号或掉入按量计费（Overage）时，提示缓存 TTL 只有 5 分钟，心跳留不住它，`quotabeat` 会在首次检测到 `ephemeral_5m` 写入时自动关掉心跳并告知你。

## 测试与排错

运行完整回归测试套件（模拟 Claude Code 注入钩子 JSON、校验退出码与状态机，通过 `QUOTABEAT_UNIT=1` 将 1 分钟压缩为 1 秒）：

```bash
bash tests/run.sh
```

排查问题时，只需建一个空文件开启钩子轨迹日志：

```bash
touch ~/.claude/quotabeat/debug
```

此后钩子每次触发的完整决策都会追加记录到 `~/.claude/quotabeat/debug.log`。

## 致谢与来历

- `Stop` 钩子 `asyncRewake` 心跳保活的思路来自 [cachebeat](https://github.com/ARahim3/cachebeat)（MIT）。
- 从本地响应头日志无感读取配额的做法来自用户的 `quota_headers.sh`。早期演进版本保留在 `archive/`。
