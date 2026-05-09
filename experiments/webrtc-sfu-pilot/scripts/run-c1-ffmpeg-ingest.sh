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
  # 只拉 compose 一份，避免与 docker logs 重复拼接 → STRIPPED 里多段「旧 ingest」干扰 grep|tail
  docker compose logs --tail=500 --no-color webrtc-sfu-pilot 2>&1 || docker compose logs --tail=500 --no-color 2>&1 || true
}

LOG=$(collect_logs)
# 去掉 compose 常见前缀「容器名 | 」
STRIPPED=$(echo "${LOG}" | sed -E 's/^[^|]+\|[[:space:]]+//')

# 日志格式：ffmpeg-ingest-h264.sh / ffmpeg-ingest-vp8.sh <host> <port>
INGEST_CMD=$(echo "${STRIPPED}" | grep -oE 'ffmpeg-ingest-(h264|vp8)\.sh[[:space:]]+[0-9.]+[[:space:]]+[0-9]+([[:space:]]+[0-9]+)?' | tail -n1)
SCRIPT_BASENAME="ffmpeg-ingest-h264.sh"
HOST=""
PORT=""
RTCP_FROM_LOG=""
if [[ -n "${INGEST_CMD}" ]]; then
  if [[ "${INGEST_CMD}" == *vp8* ]]; then
    SCRIPT_BASENAME="ffmpeg-ingest-vp8.sh"
  fi
  HOST=$(echo "${INGEST_CMD}" | awk '{print $2}')
  PORT=$(echo "${INGEST_CMD}" | awk '{print $3}')
  RTCP_FROM_LOG=$(echo "${INGEST_CMD}" | awk '{print $4}')
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
# 与 docker-compose / export MEDIASOUP_INGEST_CODEC 对齐；未 export 时默认 h264（与 server 默认一致，避免 CODEC_ENV 空导致 PT 解析走易混日志的 fallback）。
CODEC_ENV=$(echo "${MEDIASOUP_INGEST_CODEC:-h264}" | tr '[:upper:]' '[:lower:]')
case "${CODEC_ENV}" in
  h264) SCRIPT_BASENAME="ffmpeg-ingest-h264.sh" ;;
  vp8) SCRIPT_BASENAME="ffmpeg-ingest-vp8.sh" ;;
esac

# 真机/Redroid 画面：ADB screenrecord → RTP（仅 H264）。用法：C1_INGEST_SOURCE=adb npm run c1:ingest -- --local
if [[ "${C1_INGEST_SOURCE:-}" == "adb" || "${C1_INGEST_SOURCE:-}" == "android" ]]; then
  SCRIPT_BASENAME="ffmpeg-ingest-h264-adb-screenrecord.sh"
  if [[ "${CODEC_ENV}" == "vp8" ]]; then
    echo "提示: C1_INGEST_SOURCE=adb 仅支持 H264 ingest，已改用 ffmpeg-ingest-h264-adb-screenrecord.sh（与 MEDIASOUP_INGEST_CODEC=vp8 并存时请改回 h264）。" >&2
  fi
fi

# 与 docker-compose 同名的变量常被 source 进 shell（默认 35500 是给容器 Plain connect 用）。
# 默认 comedia 时 FFmpeg 不应绑 localport，否则易「Address already in use」且与 SFU 学习源口无关。
if [[ "${MEDIASOUP_INGEST_PLAIN_CONNECT:-}" != "1" ]]; then
  if [[ -n "${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-}" ]] || [[ -n "${INGEST_FFMPEG_LOCAL_PORT:-}" ]]; then
    echo "提示: 已清除宿主机 MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT / INGEST_FFMPEG_LOCAL_PORT（非 MEDIASOUP_INGEST_PLAIN_CONNECT=1 时不要传给 FFmpeg）。" >&2
  fi
  unset MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT INGEST_FFMPEG_LOCAL_PORT 2>/dev/null || true
fi

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
LP=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-}
if [[ -n "${LP}" && "${LP}" != "0" ]]; then
  echo "提示: 将使用 MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT=${LP}（须与 Plain connect 一致；35500 被占用时可换端口）" >&2
else
  echo "提示: FFmpeg 默认不绑定 localport（避免 Address already in use）；comedia 模式无需固定源口" >&2
fi
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
# 兜底：服务端固定打印「ingest PT=数字」，不依赖 awk 区块与「PT= x SSRC=」同行
if [[ -z "${PT_FROM_LOG}" ]]; then
  PT_FROM_LOG=$(echo "${STRIPPED}" | grep -oE 'ingest PT=[0-9]+' | tail -n1 | sed -n 's/.*ingest PT=//p')
fi
if [[ -n "${PT_FROM_LOG}" ]]; then
  export INGEST_PT="${PT_FROM_LOG}"
  echo "提示: 从日志解析 INGEST_PT=${INGEST_PT}（传给 ffmpeg-ingest；勿再用默认 96 除非日志如此）" >&2
fi
chmod +x "${REPO_DIR}/scripts/ffmpeg-ingest-h264.sh" "${REPO_DIR}/scripts/ffmpeg-ingest-vp8.sh" \
  "${REPO_DIR}/scripts/ffmpeg-ingest-h264-adb-screenrecord.sh" 2>/dev/null || true
RTCP_PORT_ARG=""
if [[ -n "${RTCP_FROM_LOG}" ]]; then
  RTCP_PORT_ARG="${RTCP_FROM_LOG}"
fi
# 默认无 ingest_rtcp_port= 日志行；grep 无匹配在 pipefail 下会令整条 $(…) 失败并触发 set -e 提前退出（表现为 run-c1 秒回 #、从不 exec ffmpeg）
if [[ -z "${RTCP_PORT_ARG}" ]]; then
  set +o pipefail
  _rtcp_line=$(echo "${STRIPPED}" | grep -oE 'ingest_rtcp_port=[0-9]+' | tail -n1)
  set -o pipefail
  if [[ -n "${_rtcp_line}" ]]; then
    RTCP_PORT_ARG="${_rtcp_line#ingest_rtcp_port=}"
  fi
fi
FFMPEG_ARGS=( "${HOST}" "${PORT}" )
if [[ -n "${RTCP_PORT_ARG}" && "${RTCP_PORT_ARG}" != "${PORT}" ]]; then
  FFMPEG_ARGS+=( "${RTCP_PORT_ARG}" )
  echo "提示: 独立 RTCP 端口 ${RTCP_PORT_ARG}（MEDIASOUP_INGEST_RTCP_MUX=0 / mediasoup-demo 模式）" >&2
fi
exec bash "${REPO_DIR}/scripts/${SCRIPT_BASENAME}" "${FFMPEG_ARGS[@]}"
