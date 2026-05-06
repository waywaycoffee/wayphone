#!/usr/bin/env bash
# 仅结束占用 ws-scrcpy 默认端口（8000）的进程；不要使用 pkill -f node 误杀其它 Node 服务。
# 用法: bash scripts/stop-ws-scrcpy.sh

set -euo pipefail
PORT="${WS_SCRCPY_PORT:-8000}"

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)"
else
  echo "[stop-ws-scrcpy] 需要 lsof"
  exit 1
fi

if [ -z "${PIDS}" ]; then
  echo "[stop-ws-scrcpy] 端口 ${PORT} 无监听进程。"
  exit 0
fi

echo "[stop-ws-scrcpy] 即将结束 PID: ${PIDS}"
kill ${PIDS} 2>/dev/null || true
sleep 1
if lsof -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[stop-ws-scrcpy] 仍在监听，尝试 kill -9 …"
  kill -9 ${PIDS} 2>/dev/null || true
fi
echo "[stop-ws-scrcpy] 完成。"
