// Local TCP -> Neon WebSocket bridge for the installer (M0-A runbook step 3). Some build environments reach the internet only
// through an HTTPS proxy, which cannot carry the PostgreSQL wire protocol on port 5432; Neon also accepts that protocol over
// WebSocket (the transport of its serverless driver). This bridge listens on 127.0.0.1 and forwards each TCP connection to
// wss://<endpoint-host>/v2, so psql and run_migrations.py work unchanged (use sslmode=disable towards the bridge: the
// WebSocket is TLS). The proxy from HTTPS_PROXY is used when set. Usage: node neon_ws_bridge.mjs <endpoint-host> [port]
import net from 'node:net';
import WebSocket, { createWebSocketStream } from 'ws';
import { HttpsProxyAgent } from 'https-proxy-agent';

const [host, port = '15432'] = process.argv.slice(2);
if (!host || !/^[a-z0-9.-]+\.neon\.tech$/.test(host)) { console.error('usage: neon_ws_bridge.mjs <endpoint>.neon.tech [port]'); process.exit(2); }
const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
const agent = proxy ? new HttpsProxyAgent(proxy) : undefined;
net.createServer((sock) => {
  const ws = new WebSocket(`wss://${host}/v2?address=${host}:5432`, { agent });
  ws.on('open', () => {
    const s = createWebSocketStream(ws);
    sock.pipe(s).pipe(sock);
    s.on('error', () => sock.destroy());
  });
  ws.on('error', (e) => { console.error('ws error', e.message); sock.destroy(); });
  sock.on('error', () => ws.terminate());
  sock.on('close', () => ws.terminate());
}).listen(Number(port), '127.0.0.1', () => console.log(`bridge 127.0.0.1:${port} -> wss://${host}/v2`));
