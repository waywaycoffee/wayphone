#!/usr/bin/env bash
# 比对：宿主机上正在跑的 ffmpeg 的 RTP 目的端口（rtp://127.0.0.1:PORT）
#       与 webrtc-sfu-pilot 日志里最近一次「mediasoup RTP tuple」端口是否一致。
# 不一致 → 常见为容器重启后端口变了，但 ffmpeg 仍是旧进程 / 旧命令行。
#
# 用法（experiments/webrtc-sfu-pilot）:
#   bash scripts/c1-ingest-ffmpeg-rtp-vs-pilot-log.sh
# 退出码: 0 一致 | 1 不一致 | 2 无 ffmpeg | 3 日志无 tuple
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

set +e
FF_LINE=$(pgrep -af 'ffmpeg.*rtp://127\.0\.0\.1:[0-9]+' 2>/dev/null | head -1)
set -e
FF_RTP=""
if [[ -n "${FF_LINE}" ]]; then
  FF_RTP=$(echo "${FF_LINE}" | grep -oE 'rtp://127\.0\.0\.1:[0-9]+' | head -1 | sed 's/.*://')
fi

set +e
_LOG=$(docker compose logs --tail=1200 --no-color webrtc-sfu-pilot 2>&1 || true)
set -e
STRIPPED=$(echo "${_LOG}" | sed -E 's/^[^|]+\|[[:space:]]+//')
LOG_RTP=$(echo "${STRIPPED}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*[^:]*:\([0-9][0-9]*\).*/\1/p' | tail -n 1)

# 备用：server 打的「手动: bash scripts/ffmpeg-ingest-*.sh 127.0.0.1 <rtp> [<rtcp>]」
if [[ -z "${LOG_RTP}" ]]; then
  LOG_RTP=$(
    echo "${STRIPPED}" |
      grep -oE 'ffmpeg-ingest-(h264|vp8)\.sh[[:space:]]+127\.0\.0\.1[[:space:]]+[0-9]+' |
      tail -n 1 |
      awk '{print $NF}' || true
  )
fi

echo "========== C1：ffmpeg RTP 口 vs pilot 日志 =========="
echo "ffmpeg 进程 RTP 目的端口: ${FF_RTP:-"(无：未起 ingest 或未匹配 rtp://127.0.0.1:PORT)"}"
echo "pilot 日志最近一次 tuple 端口: ${LOG_RTP:-"(无：容器未起或未打印 mediasoup RTP tuple)"}"
if [[ -n "${FF_LINE}" ]]; then
  echo "--- pgrep 首行（截断） ---"
  echo "${FF_LINE}" | head -c 240
  echo ""
fi

if [[ -z "${FF_RTP}" ]]; then
  echo "判定: 无 ffmpeg ingest → 若需推流请先 run-c1；当前 pilot 期望 RTP 端口=${LOG_RTP:-?}。"
  exit 2
fi
if [[ -z "${LOG_RTP}" ]]; then
  echo "判定: 无法从日志解析端口（MEDIASOUP_INGEST_TEST=1 且已触发 ingest 创建？）。"
  exit 3
fi
if [[ "${FF_RTP}" != "${LOG_RTP}" ]]; then
  echo "判定: **不一致** — ffmpeg 打在 ${FF_RTP}，当前 pilot 日志为 ${LOG_RTP}（多为旧进程或 pilot 已重建）。"
  echo "处理: bash scripts/c1-ingest-safe.sh stop && bash scripts/run-c1-ffmpeg-ingest.sh --local  （或 pilot-recreate 后再 run-c1）"
  exit 1
fi

echo "判定: **一致**。"
echo "（comedia 源口是否与 PlainTransport remote 一致见: bash scripts/c1-ingest-comedia-check.sh）"
exit 0
