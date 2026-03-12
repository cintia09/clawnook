const $ = id => document.getElementById(id);

const statusLabels = {
  disconnected: '未连接',
  connecting:   '连接中…',
  connected:    '✅ 已连接'
};

function updateUI(state, cfg, lastError) {
  const el = $('status');
  el.className = 'status ' + state;
  const errEl = $('error-hint');

  if (state === 'disconnected' && lastError) {
    $('status-text').textContent = '连接失败';
    if (errEl) { errEl.textContent = lastError; errEl.style.display = ''; }
  } else {
    $('status-text').textContent = statusLabels[state] || state;
    if (errEl) errEl.style.display = 'none';
  }

  if (cfg) {
    $('serverUrl').value  = cfg.serverUrl  || '';
    $('pairCode').value   = cfg.pairCode   || '';
    $('token').value      = cfg.token      || '';
    $('deviceName').value = cfg.deviceName || '';
  }

  $('btn-connect').style.display    = state === 'connected' ? 'none' : '';
  $('btn-disconnect').style.display = state === 'connected' ? ''     : 'none';
  $('btn-connect').disabled = state === 'connecting';
}

// 初始化
chrome.runtime.sendMessage({ type: 'getStatus' }, (resp) => {
  if (resp) updateUI(resp.state, resp.config, resp.lastError);
});

// 来自 background 的状态变更
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'stateChanged') {
    chrome.runtime.sendMessage({ type: 'getStatus' }, (resp) => {
      if (resp) updateUI(resp.state, resp.config, resp.lastError);
    });
  }
});

// 连接按钮
$('btn-connect').addEventListener('click', () => {
  let serverUrl  = $('serverUrl').value.trim();
  const pairCode   = $('pairCode').value.trim();
  const token      = $('token').value.trim();
  const deviceName = $('deviceName').value.trim();
  if (!serverUrl || !pairCode) {
    $('status-text').textContent = '⚠️ 请填写服务器地址和配对码';
    return;
  }
  // 自动补全协议前缀（默认 HTTPS）
  if (!/^https?:\/\//i.test(serverUrl)) {
    serverUrl = 'https://' + serverUrl;
  }
  // 基本校验：必须包含 IP 或域名
  try {
    const u = new URL(serverUrl);
    if (!u.hostname || u.hostname.length < 2) throw new Error();
  } catch {
    $('status-text').textContent = '⚠️ 服务器地址格式不正确';
    return;
  }
  $('serverUrl').value = serverUrl;
  chrome.runtime.sendMessage({
    type: 'connect', serverUrl, pairCode, token, deviceName
  });
  updateUI('connecting');
});

// 断开按钮
$('btn-disconnect').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'disconnect' });
  updateUI('disconnected');
});
