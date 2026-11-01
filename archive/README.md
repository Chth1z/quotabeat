# archive

quotabeat 取代的旧版本，原样保存（2026-11-01）：

- `cachebeat/`：ARahim3/cachebeat（MIT，LICENSE 随附）加上本机补丁（Windows 父进程修正、`forever`、跳过 api-request-blob、自行启用时同一轮继续工作），原在 `~/.claude/skills/cachebeat`。quotabeat 的心跳由它而来：Stop 钩子（asyncRewake）在闲置后叫醒会话、回一个 “.” 刷新提示缓存。
- `quota-guard-python/`：额度监视的 Python 版 skill（11-01 当天写成），由 `quota.py` 一个脚本做状态栏和钩子。quotabeat 是它的 sh 版，并合并了 cachebeat。
- 更早还有三个各自独立的额度脚本（状态栏写读数、后台轮询到线结束、再起一个等待进程等到重置），不在本仓库。
