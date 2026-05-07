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
echo "ADB host port (compose 默认 REDROID_HOST_PORT): ${PORT}"
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

ss_lines=$(ss -tlnp 2>/dev/null || true)
docker_map=$(docker port cloudphone-redroid 5555/tcp 2>/dev/null || true)

listen_ok=0
if echo "${ss_lines}" | grep -qE "127\\.0\\.0\\.1:${PORT}\\b"; then
  echo "[ok] 127.0.0.1:${PORT} is listening (ss)"
  listen_ok=1
elif echo "${ss_lines}" | grep -qE "0\\.0\\.0\\.0:${PORT}\\b|\\*:${PORT}\\b"; then
  echo "[ok] 0.0.0.0 / *:${PORT} is listening (ss)；SSH -L 到本机仍可用)"
  listen_ok=1
elif echo "${ss_lines}" | grep -qE ":${PORT}[[:space:]]"; then
  echo "[ok] 检测到 :${PORT} 在 LISTEN（ss）；请确认是否为 ADB"
  listen_ok=1
fi

if [[ "${listen_ok}" -eq 0 ]]; then
  if [[ -n "${docker_map}" ]]; then
    echo "[warn] ss 未匹配到 ${PORT}，但 docker port 有映射: ${docker_map}"
    echo "      可继续试 SSH；若仍 refused，执行: ss -tlnp | grep ${PORT}"
    listen_ok=1
  fi
fi

if [[ "${listen_ok}" -eq 0 ]]; then
  echo "[fail] 宿主机未监听 ${PORT}，且 docker port 无 5555/tcp 映射"
  echo "      常见原因：容器不是用本仓库 compose 起的，或 PortBindings 为空。"
  echo "      在 ${REPO_ROOT} 执行:"
  echo "        docker port cloudphone-redroid 5555/tcp"
  echo "        docker compose ps"
  echo "        docker compose up -d --force-recreate"
  echo "      确认 docker-compose.yml 含: 127.0.0.1:\${REDROID_HOST_PORT:-5555}:5555"
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
