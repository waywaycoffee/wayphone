#!/usr/bin/env bash
# Layer C1 推荐入口：从 docker compose / 容器日志解析 RTP host/port，再启动 ffmpeg-ingest-h264.sh。
# 用法（必须在 experiments/webrtc-sfu-pilot 目录）:
#   chmod +x scripts/run-c1-ffmpeg-ingest.sh
#   bash scripts/run-c1-ffmpeg-ingest.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

collect_logs() {
  docker compose logs --tail=400 --no-color 2>&1 || true
  cid=$(docker compose ps -q webrtc-sfu-pilot 2>/dev/null || true)
  if [[ -n "${cid}" ]]; then
    docker logs "${cid}" --tail=400 2>&1 || true
  fi
}

LOG=$(collect_logs)
# 去掉 compose 常见前缀「容器名 | 」
STRIPPED=$(echo "${LOG}" | sed -E 's/^[^|]+\|[[:space:]]+//')

# 日志格式：ffmpeg-ingest-h264.sh <host> <port>（host 可为 127.0.0.1 或 EIP，如 8.163.51.24）
HOST_PORT=$(echo "${STRIPPED}" | sed -n 's/.*ffmpeg-ingest-h264\.sh \([0-9.]*\) \([0-9][0-9]*\).*/\1 \2/p' | tail -n1)
HOST=""
PORT=""
if [[ -n "${HOST_PORT}" ]]; then
  HOST=$(echo "${HOST_PORT}" | awk '{print $1}')
  PORT=$(echo "${HOST_PORT}" | awk '{print $2}')
fi

if [[ -z "${PORT}" ]]; then
  # 备用：mediasoup RTP tuple: x.x.x.x:PORT
  TUPLE=$(echo "${STRIPPED}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n1)
  if [[ -n "${TUPLE}" ]]; then
    HOST="${TUPLE%%:*}"
    PORT="${TUPLE##*:}"
  fi
fi

if [[ -z "${PORT}" ]] || [[ -z "${HOST}" ]]; then
  echo "未能从日志解析 RTP 目标。请确认：MEDIASOUP_INGEST_TEST=1 且已 docker compose up -d --build" >&2
  echo "--- 最近日志（供排查）---" >&2
  echo "${LOG}" | tail -n 50 >&2
  exit 1
fi

if [[ "${HOST}" == "0.0.0.0" ]]; then
  HOST="127.0.0.1"
fi

echo "解析到 RTP 目标: ${HOST}:${PORT}"
chmod +x "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh"
exec bash "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh" "${HOST}" "${PORT}"
