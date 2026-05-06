#!/usr/bin/env bash
# WebRTC SFU 试点 smoke：HTTP 200 + WebSocket 信令（getRouterRtpCapabilities）
# 用法（仓库根目录）:
#   bash scripts/smoke-webrtc-sfu-pilot.sh
# 指定端口:
#   PORT=3010 bash scripts/smoke-webrtc-sfu-pilot.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PILOT="${ROOT}/experiments/webrtc-sfu-pilot"
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

if [ ! -f "${PILOT}/server.cjs" ]; then
  echo "[smoke] 缺少 ${PILOT}/server.cjs"
  exit 1
fi

if [ ! -d "${PILOT}/node_modules/mediasoup" ]; then
  echo "[smoke] 未检测到依赖，正在 npm install..."
  (cd "${PILOT}" && npm install --no-audit --no-fund)
fi

if [ ! -f "${PILOT}/public/mediasoup-client.esm.js" ]; then
  echo "[smoke] 正在 npm run build:client（mediasoup-client 浏览器包）..."
  (cd "${PILOT}" && npm run build:client)
fi

pick_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}

SMOKE_PORT="${PORT:-}"
if [ -z "${SMOKE_PORT}" ]; then
  SMOKE_PORT="$(pick_free_port)"
fi

LOG="$(mktemp -t webrtc-sfu-smoke.XXXXXX)"
cleanup() {
  if [ -n "${SPID:-}" ] && kill -0 "${SPID}" 2>/dev/null; then
    kill "${SPID}" 2>/dev/null || true
    sleep 0.3
    kill -9 "${SPID}" 2>/dev/null || true
    wait "${SPID}" 2>/dev/null || true
  fi
  rm -f "${LOG}"
}
trap cleanup EXIT

echo "[smoke] PORT=${SMOKE_PORT} (设置 PORT= 可固定端口)"
(cd "${PILOT}" && PORT="${SMOKE_PORT}" node server.cjs >"${LOG}" 2>&1) &
SPID=$!

ok_http=0
for _ in $(seq 1 30); do
  if curl -sSf "http://127.0.0.1:${SMOKE_PORT}/" >/dev/null 2>&1; then
    ok_http=1
    break
  fi
  sleep 0.2
done

if [ "${ok_http}" != 1 ]; then
  echo "[smoke] FAIL: HTTP 未在超时内就绪"
  echo "--- server log ---"
  cat "${LOG}" || true
  exit 1
fi

if ! curl -sSf "http://127.0.0.1:${SMOKE_PORT}/" | grep -q "Layer B"; then
  echo "[smoke] FAIL: 首页未包含 Layer B 标记"
  exit 1
fi

if ! (cd "${PILOT}" && node - <<NODE
const WebSocket = require('ws');
const url = 'ws://127.0.0.1:${SMOKE_PORT}';
const ws = new WebSocket(url);
const t = setTimeout(() => { console.error('ws timeout'); process.exit(2); }, 8000);
ws.on('open', () => {
  ws.send(JSON.stringify({ type: 'getRouterRtpCapabilities', requestId: 'smoke-rpc-1' }));
});
ws.on('message', (d) => {
  let m;
  try { m = JSON.parse(d.toString()); } catch { return; }
  if (m.requestId !== 'smoke-rpc-1') return;
  clearTimeout(t);
  if (!m.ok || !m.routerRtpCapabilities) {
    console.error('unexpected:', d.toString().slice(0, 400));
    process.exit(3);
  }
  ws.close();
});
ws.on('close', () => process.exit(0));
ws.on('error', (e) => { console.error(e.message); process.exit(1); });
NODE
); then
  echo "[smoke] FAIL: WebSocket 信令校验未通过"
  echo "--- server log ---"
  cat "${LOG}" || true
  exit 1
fi

if ! grep -q "mediasoup Worker + Router OK" "${LOG}"; then
  echo "[smoke] FAIL: 日志中未见 Worker+Router 就绪"
  cat "${LOG}" || true
  exit 1
fi

echo "[smoke] OK: HTTP 200 + Layer B 页面 + WS getRouterRtpCapabilities + mediasoup 日志"
echo "[smoke] 本次 URL: http://127.0.0.1:${SMOKE_PORT}/"
