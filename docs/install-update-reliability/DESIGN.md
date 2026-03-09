# 设计文档 — 安装/更新/Gateway重启 可靠性加固

> **版本**: v1.0  
> **日期**: 2026-03-09  
> **基线版本**: v1.1.150  
> **关联**: [DFMEA.md](./DFMEA.md)

---

## 1. 目标

基于 DFMEA 分析结果，修复 RPN ≥ 100 的高风险失效模式，提升安装/更新/Gateway 重启链路的可靠性。

**修复范围**：
- 🔴 P0: N4(294), N2(200), N3(180), N1(144)
- 🟡 P1: T2(168), O2(147), R1(144), G1(135), S1(128), F2(100)

---

## 2. 变更总览

| 变更编号 | 文件 | 变更摘要 | 修复 DFMEA 项 |
|----------|------|----------|---------------|
| C1 | web/server.js | npm 安装策略：从 staging-prefix 改为 backup-then-install-in-place | N4, N2, N1 |
| C2 | web/server.js | npm view 查询失败时显式标记 + 跳过版本对齐 | N3 |
| C3 | web/server.js | 安装成功后主动 ensureGatewayWatchdog | G1 |
| C4 | web/server.js | release 编译包安装增加 node --check 校验 | R1 |
| C5 | web/server.js | source 构建 control-ui 缺失时写明确状态标记 | S1 |
| C6 | web/server.js | operation.lock 写入改用 writeJsonFileAtomic | O2(部分) |
| C7 | web/server.js | runOpenClawTask 子进程 PID 持久化 + 重启后检测 orphan | T2 |
| C8 | web/public/app.js | 前端 pollTask 改为指数退避，总超时延长到 120s | F2 |

---

## 3. 详细设计

### 3.1 C1: npm 安装策略重构（N4+N2+N1）

**问题根因**：
当前 `buildOpenClawNpmInstallCommand()` 存在三层风险：
1. 开头无条件 `npm uninstall -g` + `rm -rf` 删除旧版本 (N1)
2. staging prefix 安装后 mv 替换，bin 文件含 staging 绝对路径 (N4)
3. mv 后 bin symlink 可能断裂 (N2)

**方案：backup-then-install-in-place**

核心思想：不用 staging prefix，而是**先备份旧版本目录，然后原地 npm install -g，失败时还原备份**。

```
旧流程 (v1.1.150):
  npm uninstall → rm -rf → npm install → (失败? 无可用版本)
  ...later...
  npm install --prefix staging → verify → mv staging→正式 → (bin路径断裂)

新流程:
  1. BACKUP: mv /root/.npm-global/lib/node_modules/openclaw → /root/.npm-global-backup/openclaw
  2. INSTALL: npm install -g openclaw@<version>  (原地安装到正式prefix)
  3. VERIFY: 检查 package.json + 入口文件 + openclaw -v 可执行
  4. 成功? → rm backup
  5. 失败? → rm 新安装残留 → mv backup → restore旧版本
```

**关键优势**：
- npm install -g 的 bin 路径天然正确（安装到正式 prefix）
- 旧版本有备份，安装失败可还原
- 无 staging prefix 路径断裂问题

**代码变更位置**: `buildOpenClawNpmInstallCommand()` (server.js L6738 起)

```bash
# === 旧代码（删除） ===
npm uninstall -g openclaw >/dev/null 2>&1 || true
rm -rf "${OPENCLAW_LIB_DIR}/openclaw" "${OPENCLAW_LIB_DIR}"/.openclaw-* >/dev/null 2>&1 || true

# === 新代码 ===
# 备份旧版本（如果存在）
BACKUP_LIB_DIR="/root/.npm-global-backup"
if [ -d "${OPENCLAW_LIB_DIR}/openclaw" ]; then
  rm -rf "$BACKUP_LIB_DIR" 2>/dev/null || true
  mkdir -p "$BACKUP_LIB_DIR"
  cp -a "${OPENCLAW_LIB_DIR}/openclaw" "$BACKUP_LIB_DIR/openclaw"
  echo "[openclaw] 旧版本已备份到 $BACKUP_LIB_DIR"
fi
```

同样，staging 对齐段落也改为 backup-then-install-in-place：

```bash
# === 旧代码（staging 安装，删除） ===
STAGING_PREFIX="/root/.npm-global-staging"
...
mv "$STAGING_PREFIX" "${NPM_PREFIX}"

# === 新代码 ===
# 备份当前版本
BACKUP_LIB_DIR="/root/.npm-global-backup"
rm -rf "$BACKUP_LIB_DIR" 2>/dev/null || true
if [ -d "${OPENCLAW_LIB_DIR}/openclaw" ]; then
  mkdir -p "$BACKUP_LIB_DIR"
  cp -a "${OPENCLAW_LIB_DIR}/openclaw" "$BACKUP_LIB_DIR/openclaw"
fi

# 原地安装
set +e
npm install -g "$ALIGN_PKG" --prefer-online --no-audit --no-fund 2>&1 | tee "$LOG"
ALIGN_RC=${PIPESTATUS[0]}
set -e

# 验证
if [ "$ALIGN_RC" -eq 0 ] && [ -f "${OPENCLAW_LIB_DIR}/openclaw/package.json" ]; then
  # 检查入口文件和可执行性
  verify_installed_openclaw  # 新增验证函数
  if [ $? -eq 0 ]; then
    ALIGN_OK=1
    rm -rf "$BACKUP_LIB_DIR" 2>/dev/null || true
  fi
fi

# 失败还原
if [ "$ALIGN_OK" != "1" ] && [ -d "$BACKUP_LIB_DIR/openclaw" ]; then
  echo "[openclaw] 安装失败，还原旧版本..."
  rm -rf "${OPENCLAW_LIB_DIR}/openclaw" 2>/dev/null || true
  mv "$BACKUP_LIB_DIR/openclaw" "${OPENCLAW_LIB_DIR}/openclaw"
  npm rebuild -g openclaw 2>/dev/null || true
fi
```

**新增 verify_installed_openclaw 函数**（内嵌在脚本中）：
```bash
verify_installed_openclaw() {
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/package.json" ] || return 1
  local has_entry=0
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/openclaw.mjs" ] && has_entry=1
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/dist/openclaw.mjs" ] && has_entry=1
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/dist/entry.js" ] && has_entry=1
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/dist/index.js" ] && has_entry=1
  [ -f "${OPENCLAW_LIB_DIR}/openclaw/dist/index.mjs" ] && has_entry=1
  [ "$has_entry" = "1" ] || return 1
  # bin 可执行性检查
  if command -v openclaw >/dev/null 2>&1; then
    openclaw -v >/dev/null 2>&1 || return 1
  elif [ -x "$OPENCLAW_BIN" ]; then
    "$OPENCLAW_BIN" -v >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  return 0
}
```

### 3.2 C2: npm view 失败处理（N3）

**变更位置**: `buildOpenClawNpmInstallCommand()` 中版本查询段

```bash
# 旧:
MIRROR_LATEST="$(npm view openclaw version ... || true)"
NPMJS_LATEST="$(npm view openclaw version ... || true)"

# 新: 增加查询失败标记
VERSION_QUERY_FAILED=0
MIRROR_LATEST="$(npm view openclaw version --registry=https://registry.npmmirror.com 2>/dev/null || true)"
NPMJS_LATEST="$(npm view openclaw version --registry=https://registry.npmjs.org 2>/dev/null || true)"
if [ -z "$MIRROR_LATEST" ] && [ -z "$NPMJS_LATEST" ]; then
  VERSION_QUERY_FAILED=1
  echo "[openclaw][warn] npm view 查询失败（两个源均不可用），跳过版本对齐检查"
fi
```

在版本对齐检查段增加：
```bash
# 只有在版本查询成功时才进行对齐
if [ "$VERSION_QUERY_FAILED" != "1" ] && ...; then
  # 执行对齐安装
fi
```

### 3.3 C3: 安装成功后确保 watchdog 存活（G1）

**变更位置**: `runOpenClawTask()` close 事件中，`queueGatewayRestart` 调用之前

```javascript
// 新增：安装/更新成功后，确保 watchdog 存活
if (task.status === 'success' && (operationType === 'installing' || operationType === 'updating')) {
  // ... existing metadataSync code ...
  
  // 新增: 确保 watchdog 进程存活
  ensureGatewayWatchdog((err) => {
    if (err) {
      appendInstallLog(task, `[openclaw][warn] watchdog 拉起失败: ${err.message}\n`);
    } else {
      appendInstallLog(task, `[openclaw] watchdog 存活确认\n`);
    }
  });
  
  const restartState = queueGatewayRestart(...);
  // ... rest of existing code ...
}
```

### 3.4 C4: release 编译包增加 node --check 校验（R1）

**变更位置**: `buildOpenClawReleaseAssetInstallCommand()` 解压后校验段

在现有 `if [ -z "$ASSET_ROOT" ]` 检查之后增加：

```bash
# 新增：对入口文件执行语法校验
if command -v node >/dev/null 2>&1; then
  echo "[openclaw] 校验 openclaw.mjs 语法完整性..."
  if ! node --check "$ASSET_ROOT/openclaw.mjs" 2>/dev/null; then
    echo "[openclaw][error] openclaw.mjs 语法校验失败（文件可能损坏）"
    exit 14
  fi
  echo "[openclaw] openclaw.mjs 语法校验通过"
fi
```

### 3.5 C5: source 构建 control-ui 缺失标记（S1）

**变更位置**: `buildOpenClawSourceInstallCommand()` 末尾的 control-ui 检查段

现有代码在 control-ui 缺失时 `exit 4`，这是正确的。但在多次回填后仍然缺失时，增加更明确的诊断信息：

```bash
# 现有 exit 4 之前，增加
echo "[openclaw][error] control-ui 回填失败。请检查："
echo "[openclaw][error]   1. 该版本的 build 是否包含 ui:build 脚本"
echo "[openclaw][error]   2. 全局 npm 包中是否存在 control-ui"
echo "[openclaw][error]   3. 尝试手动执行: npm run ui:build"
```

### 3.6 C6: operation.lock 原子写入（O2 部分缓解）

**变更位置**: `writeOperationLock()` (server.js L5540)

```javascript
// 旧:
function writeOperationLock(state) {
  try {
    fs.mkdirSync(path.dirname(OPENCLAW_OPERATION_LOCK_FILE), { recursive: true });
    if (!state || !state.type || state.type === 'idle') {
      if (fs.existsSync(OPENCLAW_OPERATION_LOCK_FILE)) fs.unlinkSync(OPENCLAW_OPERATION_LOCK_FILE);
      return;
    }
    fs.writeFileSync(OPENCLAW_OPERATION_LOCK_FILE, JSON.stringify(state), { mode: 0o600 });
  } catch {}
}

// 新:
function writeOperationLock(state) {
  try {
    fs.mkdirSync(path.dirname(OPENCLAW_OPERATION_LOCK_FILE), { recursive: true });
    if (!state || !state.type || state.type === 'idle') {
      if (fs.existsSync(OPENCLAW_OPERATION_LOCK_FILE)) fs.unlinkSync(OPENCLAW_OPERATION_LOCK_FILE);
      return;
    }
    writeJsonFileAtomic(OPENCLAW_OPERATION_LOCK_FILE, state, 0o600);
  } catch {}
}
```

### 3.7 C7: 子进程 PID 持久化 + orphan 检测（T2）

**变更位置**: `runOpenClawTask()` 中的 child spawn 后

```javascript
// 新增: 持久化子进程 PID
const TASK_PID_FILE = path.join(OPENCLAW_LOCK_DIR, 'install-task.pid');
try {
  fs.writeFileSync(TASK_PID_FILE, JSON.stringify({
    pid: child.pid,
    taskId,
    operationType,
    startedAt: Date.now()
  }), { mode: 0o600 });
} catch {}
```

在 close 事件中清理：
```javascript
try { fs.unlinkSync(TASK_PID_FILE); } catch {}
```

在 server.js 启动时增加 orphan 检测：
```javascript
function checkOrphanInstallTask() {
  const pidFile = path.join(OPENCLAW_LOCK_DIR, 'install-task.pid');
  try {
    if (!fs.existsSync(pidFile)) return;
    const data = JSON.parse(fs.readFileSync(pidFile, 'utf8'));
    const pid = Number(data?.pid || 0);
    if (pid <= 0) { fs.unlinkSync(pidFile); return; }
    try {
      process.kill(pid, 0); // 进程存在
      console.log(`[openclaw][orphan] Detected orphan install process pid=${pid} task=${data.taskId}, waiting for completion...`);
      // 不主动杀死，让它自然结束；但清理 operation state
    } catch {
      // 进程已死
      console.log(`[openclaw][orphan] Cleaning up dead install task pid=${pid}`);
      fs.unlinkSync(pidFile);
      clearOpenClawOperationState(String(data.operationType || ''));
    }
  } catch {}
}
```

### 3.8 C8: 前端轮询指数退避（F2）

**变更位置**: `pollTask()` (app.js L1361)

```javascript
// 旧:
if (!st || st.error) {
  errorStreak += 1;
  if (errorStreak >= 8) {
    // 放弃
  }
  return;
}

// 新: 指数退避 + 总超时 120s
if (!st || st.error) {
  errorStreak += 1;
  const totalErrorMs = Date.now() - lastSuccessAt;
  if (totalErrorMs > 120000) {
    // 连续失败超过 120 秒才放弃
    // ... 停止轮询 ...
    return;
  }
  // 指数退避：调整下次轮询间隔
  const backoffMs = Math.min(600 * Math.pow(2, errorStreak - 1), 10000);
  if (ocPollTimer) clearInterval(ocPollTimer);
  ocPollTimer = setTimeout(async () => {
    await tick();
    if (ocPollTimer) ocPollTimer = setInterval(tick, 600);
  }, backoffMs);
  return;
}
errorStreak = 0;
lastSuccessAt = Date.now();
```

---

## 4. 影响范围

| 组件 | 变更范围 | 风险 |
|------|----------|------|
| web/server.js | buildOpenClawNpmInstallCommand、runOpenClawTask close 回调、writeOperationLock、初始化段 | 中 — 安装脚本变更需在容器中实测 |
| web/public/app.js | pollTask 函数 | 低 — 仅前端轮询逻辑 |
| buildOpenClawReleaseAssetInstallCommand | 增加 node --check | 低 — 纯增加校验 |
| buildOpenClawSourceInstallCommand | 增加诊断信息 | 低 — 纯日志增强 |

## 5. 向后兼容性

- 所有变更向后兼容
- 旧版本容器升级到新版本后首次安装会采用新策略
- operation.lock 格式不变（仅写入方式改为原子）
- 前端 pollTask 改变仅影响轮询行为，API 接口不变

## 6. 回滚方案

如新版本出现问题：
1. 通过 hot-patch 回退 web/server.js 和 web/public/app.js
2. 或直接回退到 v1.1.150 tag：`git checkout v1.1.150`
