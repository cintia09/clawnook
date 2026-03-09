# DFMEA — OpenClaw 安装 / 更新 / Gateway 重启 可靠性分析

> **文档版本**: v1.0  
> **日期**: 2026-03-09  
> **分析范围**: `web/server.js` (安装/更新脚本生成 + 任务管理 + 状态管理) + `openclaw-gateway-watchdog.sh` (Gateway 重启) + `web/public/app.js` (前端轮询)  
> **当前代码版本**: v1.1.150

---

## 1. 系统架构概览

```
┌─────────┐     ┌──────────┐     ┌──────────────────┐     ┌────────────────────┐     ┌─────────┐
│ 前端     │────>│ Web API  │────>│ runOpenClawTask() │────>│ bash 安装脚本       │────>│ npm/git │
│ app.js   │<───│ server.js│<───│ (child_process)   │     │ (npm/release/src)  │     │ registry│
└─────────┘     └──────────┘     └──────────────────┘     └────────────────────┘     └─────────┘
                     │                    │
                     │              on close (成功)
                     │                    │
                     v                    v
              ┌──────────────┐    ┌───────────────────┐     ┌─────────┐
              │ operation.lock│───>│ queueGatewayRestart│────>│ watchdog│
              │ (文件锁)      │    │ (写 lock 文件)     │     │ (bash)  │
              └──────────────┘    └───────────────────┘     └─────────┘
                                                                  │
                                                            kill + start_once
                                                                  │
                                                                  v
                                                            ┌──────────┐
                                                            │ Gateway  │
                                                            │ (node)   │
                                                            └──────────┘
```

## 2. 评分标准

| 维度 | 1-3（低） | 4-6（中） | 7-10（高） |
|------|-----------|-----------|-----------|
| **严重度 S** | UI 显示异常 | 功能降级/需手动恢复 | 数据丢失/服务不可用/无法自恢复 |
| **发生度 O** | 极少/需极端条件 | 偶发/特定网络条件 | 高频/日常场景易触发 |
| **检测度 D** | 有自动检测+告警 | 有日志但需人工查看 | 静默失败/无日志 |

> **RPN** = S × O × D（≥100 为高风险需立即处理）

---

## 3. 模块一：npm 全局安装路径

`buildOpenClawNpmInstallCommand()` — server.js L6738

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **N1** | 首次 npm install 前执行 `npm uninstall -g` + `rm -rf`，旧版本被彻底删除 | 脚本开头无条件 `npm uninstall -g openclaw` + `rm -rf openclaw/` | 如果后续安装失败（网络/超时），系统无可用 openclaw 二进制；Gateway 无法重启 | 9 | 4 | 4 | **144** | 安装失败后重试一次（npmjs 源） | **删除该预清理步骤**；仅在 staging 验证通过后才清理旧版本 |
| **N2** | staging 目录 mv 后 NPM_PREFIX 被替换，但 bin 链接断裂 | `mv "$STAGING_PREFIX" "${NPM_PREFIX}"` 整个目录替换后，bin/openclaw 可能是旧绝对路径 symlink | `command -v openclaw` 找不到可执行文件，watchdog 无法启动 Gateway | 8 | 5 | 5 | **200** | `sync_openclaw_pkg_to_source` 重建 symlink | staging 切换后重新执行 bin 链接修复并验证 `openclaw -v` 可运行后再清理 backup |
| **N3** | npm view 查询版本号超时/失败，NPMJS_LATEST 为空 | 网络抖动、npm registry 不可用 | 版本比较逻辑中 NPMJS_LATEST 为空导致跳过对齐或误判 | 5 | 6 | 6 | **180** | 同时查 npmmirror 和 npmjs 两个源 | 两个源版本都查询失败时，记录 warning 并显式标记 |
| **N4** | npm install 到 staging prefix 的 bin 文件含绝对路径 shebang | npm install -g --prefix 生成指向 staging 绝对路径的 bin shebang | mv 到正式目录后，bin 文件内路径仍指向已删除的 staging 路径 | 7 | 6 | 7 | **294** | 无 | **切换后修复 bin 路径前缀**，或改用"原地安装+预备份"策略 |
| **N5** | `npm cache verify` 执行耗时过长阻塞安装进程 | npm 缓存损坏或磁盘 IO 慢 | 脚本长时间无输出，前端显示卡顿/安装超时 | 3 | 3 | 4 | 36 | 30s 心跳输出 | 给 `npm cache verify` 加 timeout 包裹（如 60s） |

## 4. 模块二：release 编译包安装路径

`buildOpenClawReleaseAssetInstallCommand()` — server.js L5940

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **R1** | 下载的 tarball/zip 校验不足，解压出损坏文件 | 网络传输中断但 curl 返回 200；CDN 返回错误页面 | 解压后 openclaw.mjs 存在但内容损坏，node 执行报语法错误 | 8 | 3 | 6 | **144** | 仅检查 http_code + 文件非空 | 增加 sha256 校验或对 openclaw.mjs 执行 `node --check` 语法校验 |
| **R2** | `rm -rf "$PERSIST_SRC_DIR"` 在 mv 之前清除旧版本 | rm + mv 之间断电/被杀 | 新旧版本同时丢失，Gateway 无法启动 | 9 | 2 | 5 | 90 | 使用了 stage 目录 | 先 mv 旧目录到 backup，再 mv stage 到正式目录 |
| **R3** | `find` 找到错误的 openclaw.mjs（多层嵌套目录） | 某些 tarball 含嵌套 node_modules 中的 openclaw.mjs | ASSET_ROOT 指向错误目录 | 6 | 2 | 5 | 60 | `head -1` 取第一个结果 | 增加 `-maxdepth 3` 限制搜索深度 |
| **R4** | GitHub 资产下载被 GFW 阻断，mirror 也不可用 | 三源均被封锁 | 重试 18 次后超时 | 6 | 5 | 3 | 90 | 三源轮换 + auto 模式回退 | 可接受；考虑增加备用源 |

## 5. 模块三：源码构建安装路径

`buildOpenClawSourceInstallCommand()` — server.js L5746

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **S1** | `npm run build` 成功但 control-ui 产物缺失 | 官方 build 脚本拆分，需额外 ui:build | Gateway /health 404，前端显示 "启动中" 永不结束 | 8 | 4 | 4 | **128** | 多次回填尝试 | 标记为半安装状态并在前端显示明确告警 |
| **S2** | `rm -rf "$PERSIST_SRC_DIR"` + `mv` 非原子 | rm + mv 之间断电 | 新旧版本全丢 | 9 | 2 | 5 | 90 | stage 目录 | 先 rename 旧目录而非删除 |
| **S3** | pnpm 版本不兼容导致 build 失败 | corepack 准备的 pnpm 版本与项目不匹配 | 构建错误退出 | 6 | 4 | 3 | 72 | fallback corepack pnpm | 读取 packageManager 字段准确安装 |

## 6. 模块四：runOpenClawTask() 任务管理

server.js L5191

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **T1** | 子进程超时被 kill 但 operation.lock 未清理 | exec 的 2700s timeout 产生 SIGTERM，close 事件中 operationType 不匹配 | operation.lock 残留，阻塞后续操作 | 8 | 2 | 5 | 80 | 超时自动过期机制（5400s） | 超时过期时主动写日志告警 |
| **T2** | Web 服务重启导致安装任务 orphan | hot-patch 或容器 restart | 安装进程继续但无人收集状态；前端轮询拿不到进度 | 7 | 4 | 6 | **168** | operation.lock 持久化 + PID 检测 | 子进程 PID 写入文件；server.js 重启后 reattach 或等待结束 |
| **T3** | installLogs 内存保留最多 5 条，旧任务日志丢失 | 频繁安装/更新 | 旧任务诊断信息丢失 | 2 | 3 | 3 | 18 | 日志同时写文件 | 现状可接受 |
| **T4** | 高频心跳 30s 对 operation.lock 频繁写入 | 每 30s setOpenClawOperationState 触发文件写入 | 磁盘 IO 负载 | 2 | 3 | 2 | 12 | — | 心跳仅写日志不写 lock 文件 |

## 7. 模块五：Gateway 重启链路

`queueGatewayRestart()` → watchdog → `start_once()`

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **G1** | 安装完成后 watchdog 进程已死，重启请求无人处理 | watchdog 被 OOM 杀死/意外退出 | 前端显示 "启动中" 直到超时（480s） | 9 | 3 | 5 | **135** | reconcileRestartingGatewayState() 检查 | 安装成功后主动检查 watchdog 存活并重新拉起 |
| **G2** | watchdog kill_gateway() 误杀其他 openclaw 进程 | `pkill -9 -x "openclaw"` 匹配所有同名进程 | 其他 openclaw CLI 操作被杀 | 5 | 3 | 6 | 90 | 先 SIGTERM 再等 5s 再 SIGKILL | pkill 匹配改为 `pkill -f "openclaw.mjs gateway"` 更精确 |
| **G3** | STARTUP_TIMEOUT=900s 过长 | Gateway 崩溃退出后仍在等待 | 用户等 15 分钟 | 5 | 4 | 3 | 60 | is_gateway_process_alive() 检查 | 现有逻辑已处理进程退出 |
| **G4** | 3 次连续失败触发 300s backoff | 配置文件连续无效 | 用户等 5 分钟 | 7 | 3 | 4 | 84 | backoff 前尝试 config rollback | backoff 期间允许 API 手动触发重启 |
| **G5** | 端口 18789 未释放（TIME_WAIT） | SIGKILL 后 TCP TIME_WAIT | 新 Gateway 绑定端口失败 | 6 | 2 | 4 | 48 | kill 后 sleep 2 + --force | 可接受 |

## 8. 模块六：前端轮询

`pollTask()` / `refreshOpenClaw()` — app.js

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **F1** | 轮询 600ms 间隔导致高频 API 调用 | setInterval(tick, 600) | ~2000 次调用/20分钟；低带宽下拥塞 | 3 | 7 | 2 | 42 | — | 动态调整间隔：安装中 2-3s，启动期 3-5s |
| **F2** | 连续 8 次轮询失败即放弃 | 网络抖动或 server.js 短暂重启 | ~4.8s 内放弃；用户需手动刷新 | 5 | 4 | 5 | **100** | toast "轮询中断" | 指数退避重试，总放弃时限延长到 60s+ |
| **F3** | pollTask 中 await refreshOpenClaw 阻塞 tick | API 响应慢时 refreshOpenClaw 超时 15s | 日志更新延迟数秒 | 3 | 4 | 4 | 48 | — | refreshOpenClaw 改为 fire-and-forget |
| **F4** | Gateway 启动轮询 5 分钟超时用户无法中断 | while 循环阻塞 | 用户不能做任何操作 | 5 | 3 | 3 | 45 | 显示 "启动中" | 增加"跳过等待"按钮 |

## 9. 模块七：operation.lock 状态管理

server.js L5484

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **O1** | operation.lock 写入一半时断电 | JSON 写入非原子 | JSON.parse 失败，状态丢失 | 7 | 2 | 4 | 56 | catch 返回 null → idle | 使用已有的 writeJsonFileAtomic |
| **O2** | web server 和 watchdog 同时读写竞态 | 两进程无文件锁 | server 写入后 watchdog 读到旧状态 | 7 | 3 | 7 | **147** | watchdog 每 10s 轮询 | 使用 flock 加锁；或 Unix signal 通知 watchdog |
| **O3** | installing 超时值 5400s (90min) 过大 | 正常安装最多 30 分钟 | 状态卡在 "安装中" 过久 | 5 | 2 | 4 | 40 | — | 无心跳输出超 5 分钟时提前过期 |

## 10. 模块八：自动恢复

`maybeTriggerOpenClawRuntimeRecovery()`

| # | 失效模式 | 失效原因 | 失效影响 | S | O | D | RPN | 现有控制措施 | 建议改进 |
|---|----------|----------|----------|---|---|---|-----|-------------|----------|
| **A1** | 自动恢复触发循环 | 3min cooldown 过短 + 网络不可用 | 每 3 分钟失败安装一次 | 4 | 4 | 3 | 48 | 3 分钟 cooldown | 指数退避：3→6→12→最大 1h |
| **A2** | 自动恢复与用户手动安装竞争 | 几乎同时触发 | 一方被拒绝 | 4 | 3 | 4 | 48 | busy 检查 | 用户操作优先，恢复延迟 |

---

## 11. 风险优先级排序（TOP 10 by RPN）

| 排名 | ID | RPN | 失效模式 | 优先级 |
|------|-----|-----|----------|--------|
| 1 | **N4** | **294** | staging prefix 的 bin 文件含绝对路径，mv 后路径断裂 | 🔴 P0 |
| 2 | **N2** | **200** | staging→正式目录 mv 后 bin 链接断裂 | 🔴 P0 |
| 3 | **N3** | **180** | npm view 版本查询失败导致版本对齐逻辑异常 | 🔴 P0 |
| 4 | **T2** | **168** | server.js 重启后安装子进程成为 orphan | 🟡 P1 |
| 5 | **O2** | **147** | operation.lock 读写竞态（web vs watchdog） | 🟡 P1 |
| 6 | **N1** | **144** | 首次安装前无条件清理旧版本 | 🟡 P1 |
| 7 | **R1** | **144** | 编译包下载损坏但校验不足 | 🟡 P1 |
| 8 | **G1** | **135** | watchdog 死亡后重启请求无人处理 | 🟡 P1 |
| 9 | **S1** | **128** | 源码构建后 control-ui 缺失 | 🟡 P1 |
| 10 | **F2** | **100** | 前端轮询 8 次失败即放弃 | 🟡 P1 |
