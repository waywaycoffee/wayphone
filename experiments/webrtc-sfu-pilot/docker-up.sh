#!/usr/bin/env bash
# 使用绝对路径调用 compose，避免部分环境（如 Snap 包 Docker）下 cwd 识别异常。
# 用法（任意 cwd）:
#   MEDIASOUP_ANNOUNCED_IP=你的公网IP PORT=3000 bash /opt/wayphone/experiments/webrtc-sfu-pilot/docker-up.sh
# 或先 cd 本目录:
#   MEDIASOUP_ANNOUNCED_IP=... bash ./docker-up.sh

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="${DIR}/docker-compose.yml"
if [ ! -f "${COMPOSE}" ]; then
  echo "缺少 ${COMPOSE}，请确认已 git clone 完整仓库。" >&2
  exit 1
fi
exec docker compose --project-directory "${DIR}" -f "${COMPOSE}" up --build "$@"
