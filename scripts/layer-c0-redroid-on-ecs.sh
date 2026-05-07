#!/usr/bin/env bash
# C0：在 ECS（仓库根目录）执行，确认 Redroid + 本机 ADB 端口就绪，并打印 Mac 侧命令模板。
# 用法：cd /opt/wayphone && bash scripts/layer-c0-redroid-on-ecs.sh
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

PORT=5555
if [[ -f .env ]]; then
  line=$(grep -E '^REDROID_HOST_PORT=' .env 2>/dev/null | tail -1 || true)
  if [[ -n "${line}" ]]; then
    val="${line#*=}"
    val="${val%$'\r'}"
    val="${val//\"/}"
    val="${val//\'/}"
    if [[ -n "${val}" ]]; then
      PORT="${val}"
    fi
  fi
fi

echo "=== C0: Redroid readiness (ECS) ==="
echo "Repo: ${REPO_ROOT}"
echo "ADB host port (expected bound to 127.0.0.1): ${PORT}"
echo ""

if ! command -v docker >/dev/null 2>&1; then
  echo "[fail] docker not in PATH"
  exit 1
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^cloudphone-redroid$'; then
  echo "[ok] container cloudphone-redroid is running"
else
  echo "[fail] cloudphone-redroid not running"
  echo "      Fix: cd ${REPO_ROOT} && docker compose up -d"
  echo "      Logs: docker logs cloudphone-redroid --tail=50"
  exit 1
fi

if ss -tlnp 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${PORT}\\b"; then
  echo "[ok] 127.0.0.1:${PORT} is listening"
else
  echo "[fail] 127.0.0.1:${PORT} not listening (SSH -L will get Connection refused)"
  echo "      Check: ss -tlnp | grep ${PORT}"
  echo "      And:   docker compose ps / docker port cloudphone-redroid 5555"
  exit 1
fi

echo ""
echo "=== Next: on your Mac (two terminals) ==="
echo "Replace EIP and the path to your .pem."
echo ""
echo "Terminal A (keep open):"
echo "  ssh -N -L ${PORT}:127.0.0.1:${PORT} -i /path/to/key.pem root@EIP"
echo ""
echo "Terminal B:"
echo "  adb connect 127.0.0.1:${PORT}"
echo "  adb devices    # expect: 127.0.0.1:${PORT}  device"
echo "  scrcpy -s 127.0.0.1:${PORT}"
echo ""
echo "Docs: docs/layer-c-roadmap.md §5"
echo "=== done ==="
