const fs = require('fs');
const crypto = require('crypto');
const { WebSocket } = require('ws');
const http = require('http');

const CONFIG_PATH = '/root/.openclaw/docker-config.json';
let config;
try {
  config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch(e) {
  console.error('Failed to read config:', e);
  process.exit(1);
}
const secret = config.webAuth?.secret;

function base64urlEncode(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function sign(payload, secret) {
  return crypto.createHmac('sha256', secret).update(payload).digest('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

const payloadObj = { u: 'admin', exp: Date.now() + 3600000 };
const payloadStr = base64urlEncode(Buffer.from(JSON.stringify(payloadObj)));
const sigStr = sign(payloadStr, secret);
const cookieVal = `${payloadStr}.${sigStr}`;

const req = http.request({
  host: '127.0.0.1',
  port: 3000,
  path: '/api/terminal/ws-token',
  headers: { 'Cookie': `oc_session=${cookieVal}` }
}, (res) => {
  let body = '';
  res.on('data', d => body += d);
  res.on('end', () => {
    let token = '';
    try { token = JSON.parse(body).token; } catch(e) {}
    console.log('Got token:', token);
    if (!token) {
      console.log('Failed to parse token from:', body);
      process.exit(1);
    }
    const ws = new WebSocket('ws://127.0.0.1:3000/api/ws/terminal?token=' + token);
    ws.on('open', () => {
      console.log('Test WS Connected!');
      ws.send(JSON.stringify({type: 'input', data: 'echo Hello from WS\r'}));
      setTimeout(() => ws.close(), 2000);
    });
    ws.on('message', (msg) => {
      console.log('Test WS received:', msg.toString());
    });
    ws.on('close', (code) => {
      console.log('Test WS Closed with code:', code);
      process.exit(code === 1000 || code === 1005 ? 0 : 1);
    });
    ws.on('error', (err) => {
      console.error('Test WS Error:', err);
      process.exit(1);
    });
  });
});
req.end();
