#!/usr/bin/env bash
# 从当前目录的 docker compose 日志解析 PlainTransport RTP 端口并启动 FFmpeg（无手填端口）。
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

PORT=$(echo "${STRIPPED}" | sed -n 's/.*ffmpeg-ingest-h264\.sh 127\.0\.0\.1 \([0-9][0-9]*\).*/\1/p' | tail -n1)

if [[ -z "${PORT}" ]]; then
  # 备用：mediasoup RTP tuple: 0.0.0.0:PORT 或 127.0.0.1:PORT
  PORT=$(echo "${STRIPPED}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*[^:[:space:]]*:\([0-9][0-9]*\).*/\1/p' | tail -n1)
fi

if [[ -z "${PORT}" ]]; then
  echo "未能从日志解析 RTP 端口。请确认：MEDIASOUP_INGEST_TEST=1 且已 docker compose up -d --build" >&2
  echo "--- 最近日志（供排查）---" >&2
  echo "${LOG}" | tail -n 50 >&2
  exit 1
fi

echo "解析到 RTP 端口: ${PORT}（目标 127.0.0.1）"
chmod +x "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh"
exec bash "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh" 127.0.0.1 "${PORT}"
