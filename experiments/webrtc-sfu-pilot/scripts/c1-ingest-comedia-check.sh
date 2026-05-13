#!/usr/bin/env bash
# 检查 PlainTransport comedia 学到的 remote 端口是否与「当前发往 RTP 口的 UDP 源端口」一致。
# adb-loop 每段重启 ffmpeg 会换临时源口；若 pilot 未重建，remote 仍绑旧口 → 黑屏 / packetCount 冻结。
#
# 用法（experiments/webrtc-sfu-pilot）:
#   bash scripts/c1-ingest-comedia-check.sh
# 退出码: 0=一致或无法判定；1=不匹配（须 pilot-recreate）；2=无 RTP 端口（未起 ingest）
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

usage() {
  echo "用法: bash scripts/c1-ingest-comedia-check.sh [--strict]" >&2
  echo "  --strict  无法抓包或缺日志时退出 2（默认可判定才严格失败）" >&2
  exit 0
}
STRICT=0
for a in "$@"; do
  case "${a}" in
    --strict) STRICT=1 ;;
    -h | --help) usage ;;
    *) echo "unknown arg: ${a}" >&2; exit 1 ;;
  esac
done

RTP_PORT=""
set +e
_FF_OUT=$(pgrep -af 'ffmpeg.*rtp://127\.0\.0\.1:[0-9]+' 2>/dev/null || true)
set -e
if [[ -n "${_FF_OUT}" ]]; then
  RTP_PORT=$(echo "${_FF_OUT}" | grep -oE 'rtp://127\.0\.0\.1:[0-9]+' | head -1 | sed 's/.*://')
fi
if [[ -z "${RTP_PORT}" ]]; then
  set +e
  _log=$(docker compose logs --tail=600 --no-color webrtc-sfu-pilot 2>/dev/null || true)
  _tuple=$(echo "${_log}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n 1)
  RTP_PORT=${_tuple##*:}
  set -e
fi

if [[ -z "${RTP_PORT}" ]]; then
  echo "c1-ingest-comedia-check: 无 RTP 端口（无 ffmpeg 且无 mediasoup RTP tuple 日志）。请先启动 ingest。" >&2
  exit 2
fi

set +e
_LOG=$(docker compose logs --tail=800 --no-color webrtc-sfu-pilot 2>/dev/null || true)
REMOTE_LINE=$(echo "${_LOG}" | grep -E 'PlainTransport stats.*remote=127\.0\.0\.1:[0-9]+' | tail -n 1)
REMOTE_PORT=$(echo "${REMOTE_LINE}" | grep -oE 'remote=127\.0\.0\.1:[0-9]+' | head -1 | sed 's/.*://')
set -e

if [[ -z "${REMOTE_PORT}" ]]; then
  echo "c1-ingest-comedia-check: 日志中无 remote=（试点未跑过 ingest 统计？）。无法比对。" >&2
  [[ "${STRICT}" == 1 ]] && exit 2
  exit 0
fi

if ! command -v tcpdump >/dev/null 2>&1; then
  echo "c1-ingest-comedia-check: 未安装 tcpdump，无法抓源端口。apt-get install -y tcpdump" >&2
  [[ "${STRICT}" == 1 ]] && exit 2
  exit 0
fi

set +e
set +o pipefail
_TD_OUT=$(timeout 4 tcpdump -ni lo -c 1 "udp and dst port ${RTP_PORT}" 2>&1)
set -o pipefail
set -e

# 匹配: IP 127.0.0.1.49305 > 127.0.0.1.47830
SRC_LINE=$(echo "${_TD_OUT}" | grep -E "127\\.0\\.0\\.1\\.[0-9]+ > 127\\.0\\.0\\.1\\.${RTP_PORT}" | head -1 || true)
SRC_PORT=$(echo "${SRC_LINE}" | sed -n 's/.*IP 127\.0\.0\.1\.\([0-9]*\) >.*/\1/p')
if [[ -z "${SRC_PORT}" ]]; then
  SRC_PORT=$(echo "${SRC_LINE}" | sed -n 's/.* \([0-9]*\) > 127\.0\.0\.1\.'"${RTP_PORT}"'.*/\1/p')
fi

if [[ -z "${SRC_PORT}" ]]; then
  echo "c1-ingest-comedia-check: 4s 内未抓到 udp dst ${RTP_PORT}（ingest 未发 RTP / 段间隙）。日志 remote=${REMOTE_PORT}。" >&2
  [[ "${STRICT}" == 1 ]] && exit 2
  exit 0
fi

if [[ "${SRC_PORT}" != "${REMOTE_PORT}" ]]; then
  echo "c1-ingest-comedia-check: **不匹配** — 日志 PlainTransport remote 端口=${REMOTE_PORT}，当前 RTP 源端口=${SRC_PORT}（RTP 目的端口=${RTP_PORT}）。" >&2
  echo "  典型原因: adb-loop 重启 ffmpeg 后换源口，comedia 仍绑旧口 → 黑屏 / FFmpeg→SFU 统计冻结。" >&2
  echo "  处理: bash scripts/c1-ingest-safe.sh stop && bash scripts/c1-ingest-safe.sh pilot-recreate && bash scripts/c1-ingest-safe.sh adb-loop" >&2
  echo "  避免复发: ① 拉长 export SCREENRECORD_TIME_LIMIT=120；或 ② export C1_ADB_LOOP_PILOT_RECREATE_PER_SEGMENT=1 再 adb-loop（每段后自动 recreate，有数秒中断）。" >&2
  exit 1
fi

echo "c1-ingest-comedia-check: OK — remote=${REMOTE_PORT} 与当前 RTP 源端口=${SRC_PORT} 一致（RTP=${RTP_PORT}）。"
exit 0
