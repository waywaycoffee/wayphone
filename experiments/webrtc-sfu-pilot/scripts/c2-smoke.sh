#!/usr/bin/env bash
# ECS 宿主机：检查 C2 API 与 pilot 容器内 adb 是否可用（experiments/webrtc-sfu-pilot 目录）。
#   bash scripts/c2-smoke.sh
#   PORT=3000 bash scripts/c2-smoke.sh
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"
PORT="${PORT:-3000}"

echo "=== GET http://127.0.0.1:${PORT}/api/c2/status ==="
curl -sS "http://127.0.0.1:${PORT}/api/c2/status" || true
echo ""

echo "=== pilot 容器内 adb（须镜像已装 android-tools-adb）==="
set +e
docker compose exec -T webrtc-sfu-pilot sh -lc '
  command -v adb >/dev/null 2>&1 || { echo "no adb in container — docker compose build --no-cache"; exit 1; }
  adb version | head -1
  adb devices
  S="${C2_ADB_SERIAL:-127.0.0.1:5555}"
  echo "C2_ADB_SERIAL=$S"
  adb connect "$S" 2>/dev/null || true
  adb -s "$S" shell echo c2-smoke-ok
' 2>&1
set -e

echo ""
echo "=== POST /api/c2/tap（中心点探针；须 PILOT_C2_ENABLED=1）==="
curl -sS -X POST "http://127.0.0.1:${PORT}/api/c2/tap" \
  -H 'Content-Type: application/json' \
  -d '{"vx":360,"vy":640,"vw":720,"vh":1280}' || true
echo ""
