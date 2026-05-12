#!/usr/bin/env bash
# C1 ingest 安全周期：停干净 → 可选重建 pilot → 单路前台 ingest。
# 避免：双 ffmpeg 同 RTP 口、PlainTransport comedia 绑死旧源口（bytes 狂涨但 packetCount 卡 52）、grep 日志混旧行误判。
#
# 用法（在 experiments/webrtc-sfu-pilot，或任意目录 bash 绝对路径本脚本）:
#   bash scripts/c1-ingest-safe.sh stop
#   bash scripts/c1-ingest-safe.sh status
#   bash scripts/c1-ingest-safe.sh pilot-recreate
#   bash scripts/c1-ingest-safe.sh --recreate-pilot colorbar
#   bash scripts/c1-ingest-safe.sh adb
#   bash scripts/c1-ingest-safe.sh adb-loop
#
# 选项（须写在子命令之前）:
#   --recreate-pilot   在 colorbar / adb / adb-loop 前执行 docker compose up -d --force-recreate
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

usage() {
  cat <<'EOF'
用法（在 experiments/webrtc-sfu-pilot）:
  bash scripts/c1-ingest-safe.sh stop
  bash scripts/c1-ingest-safe.sh status
  bash scripts/c1-ingest-safe.sh pilot-recreate
  bash scripts/c1-ingest-safe.sh colorbar
  bash scripts/c1-ingest-safe.sh --recreate-pilot colorbar
  bash scripts/c1-ingest-safe.sh adb
  bash scripts/c1-ingest-safe.sh adb-loop
选项（写在子命令前）: --recreate-pilot
EOF
  exit "${1:-0}"
}

RECREATE_PILOT=0
ARGS=()
for a in "$@"; do
  case "${a}" in
    -h | --help) usage 0 ;;
    --recreate-pilot) RECREATE_PILOT=1 ;;
    *) ARGS+=("${a}") ;;
  esac
done
set -- "${ARGS[@]}"

cmd="${1:-}"
[[ -n "${cmd}" ]] || usage 1

_stop_all() {
  echo "$(date -Is) [c1-ingest-safe] stop: 结束 ingest / adb loop 相关进程…" >&2
  pkill -f 'run-c1-ingest-adb-loop\.sh' 2>/dev/null || true
  pkill -f 'c1-ingest-adb-loop' 2>/dev/null || true
  pkill -f 'ffmpeg-ingest-h264-adb-screenrecord' 2>/dev/null || true
  pkill -f 'ffmpeg-ingest-h264\.sh' 2>/dev/null || true
  pkill -f 'ffmpeg-ingest-vp8\.sh' 2>/dev/null || true
  # 兜底：宿主上发往 127.0.0.1 的 RTP ffmpeg（勿在有其它合法 ffmpeg 任务时盲用）
  pkill -9 -f 'ffmpeg.*rtp://127\.0\.0\.1' 2>/dev/null || true
  sleep 1
  if pgrep -af ffmpeg >/dev/null 2>&1; then
    echo "$(date -Is) [c1-ingest-safe] warn: 仍有 ffmpeg，请人工 pgrep -af ffmpeg 检查后手动 kill" >&2
    pgrep -af ffmpeg >&2 || true
  else
    echo "$(date -Is) [c1-ingest-safe] stop: OK（无 ffmpeg）" >&2
  fi
}

_pilot_recreate() {
  echo "$(date -Is) [c1-ingest-safe] pilot-recreate: docker compose up -d --force-recreate …" >&2
  docker compose up -d --force-recreate
  echo "$(date -Is) [c1-ingest-safe] 等待 pilot 就绪 5s…" >&2
  sleep 5
  docker compose ps >&2
}

_maybe_recreate() {
  if [[ "${RECREATE_PILOT}" == 1 ]]; then
    _pilot_recreate
  fi
}

_hints() {
  echo "" >&2
  echo "── 备忘（tcpdump 端口 = pgrep 里 rtp://127.0.0.1:<端口>，勿手写旧端口）──" >&2
  echo "  RTP=\$(pgrep -af 'rtp://127.0.0.1' | grep -oE 'rtp://127.0.0.1:[0-9]+' | head -1 | sed 's/.*://')" >&2
  echo "  timeout 3 tcpdump -ni lo udp port \"\${RTP}\" -c 20" >&2
  echo "── 浏览器：新标签 → 硬刷新 → 只点「仅观看」；黑屏先看是否仍有多条 ffmpeg ──" >&2
}

case "${cmd}" in
  stop) _stop_all ;;
  status)
    pgrep -af ffmpeg 2>/dev/null || echo "(无 ffmpeg)"
    ;;
  pilot-recreate) _pilot_recreate ;;
  colorbar)
    _stop_all
    _maybe_recreate
    unset C1_INGEST_SOURCE 2>/dev/null || true
    export -n C1_INGEST_SOURCE 2>/dev/null || true
    echo "$(date -Is) [c1-ingest-safe] 前台启动彩条 ingest（unset C1_INGEST_SOURCE）… Ctrl+C 结束" >&2
    _hints
    exec bash "${REPO_DIR}/scripts/run-c1-ffmpeg-ingest.sh" --local
    ;;
  adb)
    _stop_all
    _maybe_recreate
    export C1_INGEST_SOURCE=adb
    export MEDIASOUP_INGEST_CODEC="${MEDIASOUP_INGEST_CODEC:-h264}"
    echo "$(date -Is) [c1-ingest-safe] 前台启动 ADB ingest… Ctrl+C 结束（SCREENRECORD_TIME_LIMIT=${SCREENRECORD_TIME_LIMIT:-未设}）" >&2
    _hints
    exec bash "${REPO_DIR}/scripts/run-c1-ffmpeg-ingest.sh" --local
    ;;
  adb-loop)
    _stop_all
    _maybe_recreate
    echo "$(date -Is) [c1-ingest-safe] 前台启动 ADB ingest 循环… Ctrl+C 结束" >&2
    _hints
    exec bash "${REPO_DIR}/scripts/run-c1-ingest-adb-loop.sh"
    ;;
  *)
    echo "unknown subcommand: ${cmd}" >&2
    usage 1
    ;;
esac
