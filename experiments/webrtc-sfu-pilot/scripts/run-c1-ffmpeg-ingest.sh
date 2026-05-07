#!/usr/bin/env bash
# Layer C1 推荐入口：从 docker compose / 容器日志解析 RTP host/port，再启动 ffmpeg-ingest-h264.sh 或 ffmpeg-ingest-vp8.sh。
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

# 日志格式：ffmpeg-ingest-h264.sh / ffmpeg-ingest-vp8.sh <host> <port>
INGEST_CMD=$(echo "${STRIPPED}" | grep -oE 'ffmpeg-ingest-(h264|vp8)\.sh[[:space:]]+[0-9.]+[[:space:]]+[0-9]+' | tail -n1)
SCRIPT_BASENAME="ffmpeg-ingest-h264.sh"
HOST=""
PORT=""
if [[ -n "${INGEST_CMD}" ]]; then
  if [[ "${INGEST_CMD}" == *vp8* ]]; then
    SCRIPT_BASENAME="ffmpeg-ingest-vp8.sh"
  fi
  HOST=$(echo "${INGEST_CMD}" | awk '{print $2}')
  PORT=$(echo "${INGEST_CMD}" | awk '{print $3}')
fi

if [[ -z "${PORT}" ]]; then
  # 备用：mediasoup RTP tuple: x.x.x.x:PORT
  TUPLE=$(echo "${STRIPPED}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n1)
  if [[ -n "${TUPLE}" ]]; then
    HOST="${TUPLE%%:*}"
    PORT="${TUPLE##*:}"
    CODEC="${MEDIASOUP_INGEST_CODEC:-h264}"
    if [[ "${CODEC}" == "vp8" ]]; then
      SCRIPT_BASENAME="ffmpeg-ingest-vp8.sh"
    fi
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

echo "解析到 RTP 目标: ${HOST}:${PORT}（脚本: ${SCRIPT_BASENAME}）"
chmod +x "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh" "${REPO_DIR}/scripts/ffmpeg-ingest-vp8.sh"
exec bash "${REPO_DIR}/scripts/${SCRIPT_BASENAME}" "${HOST}" "${PORT}"
