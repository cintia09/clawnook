# OpenClaw Release 自动监控与回归测试

本文档定义了从上游 GitHub Release 发现新版本，到容器内自动更新、回归验证、失败自愈重试的完整流程。

## 1. 流程目标

- 持续监控上游 `openclaw/openclaw` 最新 Release。
- 发现新版本后，自动登录容器并执行安装/更新。
- 执行覆盖关键路径与边界条件的回归测试。
- 测试失败时执行有限自愈（重启 web、watchdog、gateway），并重测。
- 成功后记录状态，避免重复处理同一版本。

## 2. 测试矩阵（含边界条件）

### A. Release 发现阶段

1) 正常路径
- GitHub API 返回 200，`tag_name` 有效。
- 与本地 state 不同，触发升级。

2) 边界条件
- API 超时/网络抖动：重试并等待下一轮。
- API 结构异常（无 `tag_name`）：标记失败，不触发升级。
- 命中同一 tag：跳过升级。

### B. 容器连接与认证阶段

1) 正常路径
- SSH 可达，容器可执行命令。
- 可读取 `/root/.openclaw/docker-config.json` 的 `webAuth.secret`。

2) 边界条件
- SSH 连接失败：本轮失败，等待下一轮。
- `webAuth.secret` 缺失：尝试自愈重启 web 后再次读取。
- `jq` 或 `node` 缺失：直接失败并输出环境错误。

### C. 安装/更新任务阶段

1) 正常路径
- `/api/openclaw` 可读。
- 未安装走 `POST /api/openclaw/install`，已安装走 `POST /api/openclaw/update`。
- 返回 `taskId` 后轮询 `/api/openclaw/install/:taskId` 直到 `success`。

2) 边界条件
- 已有任务进行中：复用已有 taskId。
- 任务超时：标记失败，进入自愈后重试。
- 任务失败（编译失败、下载失败、依赖失败）：输出日志并失败。

### D. 网关重启与watchdog阶段

1) 正常路径
- 调用 `POST /api/openclaw/start`。
- watchdog 存在，gateway 端口和健康检查恢复。

2) 边界条件
- watchdog 未运行：先拉起 watchdog 再重测。
- gateway 不健康：触发 start，再次校验。

### E. 回归验证阶段（最小可用）

1) 必测
- `/api/openclaw` 返回结构完整，含运行状态字段。
- `/api/openclaw/config/backups` 可访问。
- watchdog 进程存在。
- gateway 健康检查返回 200/401/403 之一（按鉴权模式允许）。

2) 选测（配置文件存在时）
- 备份恢复链路可用：创建临时备份并调用 restore 验证。

### F. 自愈策略阶段

- 每轮失败最多执行 `MAX_FIX_ATTEMPTS` 次自愈：
  1. 重启 web panel（node server.js）
  2. 重启 watchdog
  3. 触发 gateway start
- 每次自愈后重新执行回归验证。
- 超过重试次数后失败退出，等待下轮监控或人工介入。

## 3. 成功判定

当且仅当以下条件全部满足：

- 安装/更新任务状态为 `success`
- gateway 健康检查可通过（200/401/403）
- watchdog 进程存在
- 回归检查全部通过

## 4. 脚本与职责

- `scripts/openclaw-release-monitor.sh`
  - 监控 GitHub Release
  - 管理本地 state
  - 触发容器升级测试脚本

- `scripts/openclaw-remote-update-and-test.sh`
  - 在容器内执行升级
  - 轮询任务、重启 gateway
  - 执行回归测试与自愈重试

## 5. 运行示例

一次性检查：

```bash
bash scripts/openclaw-release-monitor.sh --once
```

持续监控（每 5 分钟）：

```bash
bash scripts/openclaw-release-monitor.sh --watch --interval 300
```

指定目标与仓库：

```bash
SSH_HOST=root@192.168.31.107 SSH_PORT=2223 OPENCLAW_REPO=openclaw/openclaw \
  bash scripts/openclaw-release-monitor.sh --watch
```
