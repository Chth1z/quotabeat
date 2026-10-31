# archive

quotabeat 取代的旧版本，原样保存（2026-11-01）：

- `cachebeat/`：ARahim3/cachebeat（MIT，LICENSE 随附）加上本机补丁（Windows 父进程修正、`forever`、跳过 api-request-blob、自行启用时同一轮继续工作），原在 `~/.claude/skills/cachebeat`。quotabeat 的心跳由它而来：Stop 钩子（asyncRewake）在闲置后叫醒会话、回一个 “.” 刷新提示缓存。
- `quota-guard-python/`：额度监视的 Python 版 skill（11-01 当天写成，曾在 SpireZero 仓库的 `quota-guard` 分支），由 `quota.py` 一个脚本做状态栏和钩子。quotabeat 是它的 sh 版，并合并了 cachebeat。
- 更早的三个脚本（`quota_statusline.py`、`quota_watch.py`、`quota_wait.py`：后台轮询、到线结束、再起一个等待进程）归档在 SpireZero 仓库的 `archive/code/tools/`。
