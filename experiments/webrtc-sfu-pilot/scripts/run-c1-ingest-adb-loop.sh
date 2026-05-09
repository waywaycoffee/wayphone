#!/usr/bin/env bash
# ADB→RTP ingest 退出后自动重启（screenrecord/adb 管道 EOF、网络闪断、Redroid 限长等常见）。
# 用法（在 experiments/webrtc-sfu-pilot 目录）:
#   export ANDROID_SERIAL=127.0.0.1:5555
#   npm run c1:ingest:adb:loop
# 或: bash scripts/run-c1-ingest-adb-loop.sh
set -u
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
export C1_INGEST_SOURCE=adb
export MEDIASOUP_INGEST_CODEC="${MEDIASOUP_INGEST_CODEC:-h264}"
SLEEP_SEC="${C1_INGEST_LOOP_SLEEP:-2}"

while true; do
  echo "$(date -Is) c1:ingest:adb 启动…" >&2
  if bash scripts/run-c1-ffmpeg-ingest.sh --local; then
    echo "$(date -Is) ingest 正常结束（罕见）" >&2
  else
    echo "$(date -Is) ingest 退出 code=$?，${SLEEP_SEC}s 后重试" >&2
  fi
  sleep "${SLEEP_SEC}"
done
