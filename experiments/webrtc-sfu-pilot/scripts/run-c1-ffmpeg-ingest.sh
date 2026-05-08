#!/usr/bin/env bash
# Layer C1 推荐入口：从 docker compose / 容器日志解析 RTP host/port，再启动 ffmpeg-ingest-h264.sh 或 ffmpeg-ingest-vp8.sh。
# 用法（必须在 experiments/webrtc-sfu-pilot 目录）:
#   chmod +x scripts/run-c1-ffmpeg-ingest.sh
#   bash scripts/run-c1-ffmpeg-ingest.sh
#   bash scripts/run-c1-ffmpeg-ingest.sh --local   # 强制 127.0.0.1（覆盖 C1_USE_LOOPBACK=0）
set -euo pipefail

FORCE_LOCAL=0
for arg in "$@"; do
  if [[ "${arg}" == "--local" ]]; then
    FORCE_LOCAL=1
  fi
done

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

# 与当前容器配置一致：日志里常有「上次 VP8 / 上次 H264」残留，勿仅用 grep|tail 猜编码。
# 与 docker-compose / export MEDIASOUP_INGEST_CODEC 对齐（推荐与运行中的 SFU 相同）。
CODEC_ENV=$(echo "${MEDIASOUP_INGEST_CODEC:-}" | tr '[:upper:]' '[:lower:]')
case "${CODEC_ENV}" in
  h264) SCRIPT_BASENAME="ffmpeg-ingest-h264.sh" ;;
  vp8) SCRIPT_BASENAME="ffmpeg-ingest-vp8.sh" ;;
esac

if [[ "${HOST}" == "0.0.0.0" ]]; then
  HOST="127.0.0.1"
fi

# 与 Docker host 网络 + mediasoup 绑 0.0.0.0 时，FFmpeg 发往「本机 EIP」常因 UDP hairpin 丢包，SFU 收不到真实媒体（浏览器仍可能有一点 SRTP 字节但 framesDecoded=0）。
# 默认同机用 127.0.0.1；FFmpeg 在另一台机器上时再：export C1_USE_LOOPBACK=0
USE_LOOPBACK=${C1_USE_LOOPBACK:-1}
if [[ "${FORCE_LOCAL}" == "1" ]]; then
  if [[ "${HOST}" != "127.0.0.1" ]]; then
    echo "提示: --local 已指定，RTP 目标固定为 127.0.0.1:${PORT}（原 host=${HOST}，避免本机→EIP UDP hairpin）" >&2
  fi
  HOST="127.0.0.1"
elif [[ "${USE_LOOPBACK}" == "1" ]] && [[ "${HOST}" != "127.0.0.1" ]]; then
  echo "提示: RTP 改为 127.0.0.1:${PORT}（原日志 host=${HOST}，避免本机→EIP UDP hairpin）。跨机 ingest 请 C1_USE_LOOPBACK=0" >&2
  HOST="127.0.0.1"
fi

echo "解析到 RTP 目标: ${HOST}:${PORT}（脚本: ${SCRIPT_BASENAME}）"
if [[ -z "${CODEC_ENV}" ]]; then
  echo "提示: 若脚本选错（残留旧 VP8/H264 日志），请 export MEDIASOUP_INGEST_CODEC=h264|vp8 与 SFU 一致" >&2
fi
LP=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-35500}
echo "提示: rtp URL localport=${LP}（默认 SFU comedia 不要求固定源口；仅 MEDIASOUP_INGEST_PLAIN_CONNECT=1 时须 tcpdump 验证真从该口发出）" >&2
# PT：取「最后一次出现的 PlainTransport H264/VP8」区块内的 PT=…（避免混用 101 与 103）
PT_FROM_LOG=""
if [[ "${CODEC_ENV}" == "h264" ]]; then
  PT_FROM_LOG=$(
    printf '%s\n' "${STRIPPED}" | awk '
      index($0, "PlainTransport H264") { buf = $0 "\n"; grab = 1; next }
      index($0, "PlainTransport VP8") { grab = 0 }
      grab { buf = buf $0 "\n" }
      END { print buf }
    ' | grep -oE 'PT=[0-9]+[[:space:]]+SSRC=' | tail -n1 | sed -n 's/PT=\([0-9]*\).*/\1/p'
  )
elif [[ "${CODEC_ENV}" == "vp8" ]]; then
  PT_FROM_LOG=$(
    printf '%s\n' "${STRIPPED}" | awk '
      index($0, "PlainTransport VP8") { buf = $0 "\n"; grab = 1; next }
      index($0, "PlainTransport H264") { grab = 0 }
      grab { buf = buf $0 "\n" }
      END { print buf }
    ' | grep -oE 'PT=[0-9]+[[:space:]]+SSRC=' | tail -n1 | sed -n 's/PT=\([0-9]*\).*/\1/p'
  )
fi
if [[ -z "${PT_FROM_LOG}" ]]; then
  PT_FROM_LOG=$(echo "${STRIPPED}" | grep -oE 'PT=[0-9]+[[:space:]]+SSRC=' | tail -n1 | sed -n 's/PT=\([0-9]*\).*/\1/p')
fi
if [[ -n "${PT_FROM_LOG}" ]]; then
  export INGEST_PT="${PT_FROM_LOG}"
  echo "提示: 从日志解析 INGEST_PT=${INGEST_PT}（传给 ffmpeg-ingest；勿再用默认 96 除非日志如此）" >&2
fi
chmod +x "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh" "${REPO_DIR}/scripts/ffmpeg-ingest-vp8.sh"
exec bash "${REPO_DIR}/scripts/${SCRIPT_BASENAME}" "${HOST}" "${PORT}"
