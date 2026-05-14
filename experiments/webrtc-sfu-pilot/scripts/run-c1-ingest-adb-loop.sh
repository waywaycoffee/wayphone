#!/usr/bin/env bash
# ADB→RTP ingest 退出后自动重启（screenrecord/adb 管道 EOF、网络闪断、Redroid 限长等常见）。
# 用法（在 experiments/webrtc-sfu-pilot 目录）:
#   npm run c1:ingest:adb:loop
# 多台 device 时自动优先 127.0.0.1:5555（Redroid）；否则请 export ANDROID_SERIAL=… 或 C1_ADB_SERIAL=…
#
# comedia 与多段 ffmpeg（默认 PlainTransport 只学一次源口）:
#   export C1_ADB_LOOP_PILOT_RECREATE_PER_SEGMENT=1
#   每段 ingest 结束后自动 docker compose up -d --force-recreate，下一段会重新学源口（有数秒中断，换 RTP 口后须重跑 run-c1）。
#   更轻量: 拉长 SCREENRECORD_TIME_LIMIT，减少段数。
set -u
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
_def_out=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh") || exit 1
eval "${_def_out}"
export C1_INGEST_SOURCE=adb
export MEDIASOUP_INGEST_CODEC="${MEDIASOUP_INGEST_CODEC:-h264}"
SLEEP_SEC="${C1_INGEST_LOOP_SLEEP:-2}"

while true; do
  echo "$(date -Is) c1:ingest:adb 启动…" >&2
  if bash scripts/run-c1-ffmpeg-ingest.sh --local; then
    echo "$(date -Is) ingest 以 exit 0 结束（多为 screenrecord 段结束 / adb exec-out 管道 EOF；${SLEEP_SEC}s 后重拉 run-c1）" >&2
  else
    echo "$(date -Is) ingest 退出 code=$?，${SLEEP_SEC}s 后重试" >&2
  fi

  if [[ "${C1_ADB_LOOP_PILOT_RECREATE_PER_SEGMENT:-0}" == "1" ]]; then
    echo "$(date -Is) C1_ADB_LOOP_PILOT_RECREATE_PER_SEGMENT=1 → docker compose up -d --force-recreate（刷新 comedia / 新 RTP 元组）…" >&2
    set +e
    docker compose up -d --force-recreate 2>&1 | tail -n 5
    set -e
    echo "$(date -Is) 等待 pilot 就绪 6s…" >&2
    sleep 6
  fi

  sleep "${SLEEP_SEC}"
done
