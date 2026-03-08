const fs = require('fs');
const crypto = require('crypto');
const { WebSocket } = require('ws');
const https = require('https');

const CONFIG_PATH = '/root/.openclaw/docker-config.json';
let config;
try { config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')); } catch(e) { process.exit(1); }
const secret = config.webAuth?.secret;

function base64urlEncode(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
function sign(payload, secret) {
  return crypto.createHmac('sha256', secret).update(payload).digest('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
// FIXED: use 'exp' not 'e' — server getSession checks obj.exp
const payloadObj = { u: 'admin', exp: Date.now() + 3600000 };
const payloadStr = base64urlEncode(Buffer.from(JSON.stringify(payloadObj)));
const sigStr = sign(payloadStr, secret);
const cookieVal = `${payloadStr}.${sigStr}`;

console.log('Step 1: Getting ws-token via Caddy HTTPS...');
const req = https.request({
  host: '192.168.31.107',
  port: 443,
  path: '/api/terminal/ws-token',
  rejectUnauthorized: false,
  headers: { 'Cookie': `oc_session=${cookieVal}` }
}, (res) => {
  let body = '';
  res.on('data', d => body += d);
  res.on('end', () => {
    console.log('Step 1 response status:', res.statusCode);
    let token = '';
    try { token = JSON.parse(body).token; } catch(e) {}
    console.log('Got token via Caddy:', token);
    if (!token) {
      console.log('No token! Body:', body);
      process.exit(1);
    }
    
    console.log('Step 2: Connecting WSS via Caddy...');
    const ws = new WebSocket('wss://192.168.31.107/api/ws/terminal?token=' + token, {
      rejectUnauthorized: false
    });
    
    ws.on('unexpected-response', (request, response) => {
      console.log('Unexpected HTTP response from Caddy:', response.statusCode);
      let resBody = '';
      response.on('data', chunk => resBody += chunk);
      response.on('end', () => { console.log('Response body:', resBody); process.exit(1); });
    });
    
    ws.on('open', () => {
      console.log('Step 2: WSS via Caddy Connected!');
      ws.send(JSON.stringify({type: 'input', data: 'echo CADDY_TEST_OK\r'}));
      setTimeout(() => { ws.close(); }, 1500);
    });
    ws.on('message', (msg) => { console.log('WS received:', msg.toString()); });
    ws.on('close', (code) => { console.log('WS Closed code:', code); process.exit(0); });
    ws.on('error', (err) => { console.error('WS Error:', err.message); process.exit(1); });
  });
});
req.on('error', (e) => { console.error('HTTPS error:', e.message); process.exit(1); });
req.end();
