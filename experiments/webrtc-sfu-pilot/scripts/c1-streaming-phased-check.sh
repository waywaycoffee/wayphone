#!/usr/bin/env bash
# Redroid / ECS 上「串流找因」分层自检：版本 → adb/ffmpeg →（可选）ingest 日志快照。
# 在 experiments/webrtc-sfu-pilot 目录执行：
#   bash scripts/c1-streaming-phased-check.sh
# 多设备时自动优先 127.0.0.1:5555；否则 export ANDROID_SERIAL 或 C1_ADB_SERIAL
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
_def=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh") || exit 1
eval "${_def}"

ADB_FLAGS=()
[[ -n "${ANDROID_SERIAL:-}" ]] && ADB_FLAGS+=(-s "${ANDROID_SERIAL}")

echo "========== 0) 容器内 Android 版本（Redroid 9 期望 sdk=28）=========="
if command -v adb >/dev/null 2>&1; then
  adb "${ADB_FLAGS[@]}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' || echo "(无法读取 sdk — 先 adb connect)"
  adb "${ADB_FLAGS[@]}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || true
else
  echo "(未安装 adb)"
fi

echo
echo "========== 1) ADB + FFmpeg 前置（不过则勿跑 ingest）=========="
bash scripts/check-c1-adb-prereqs.sh

echo
echo "========== 2) SFU / ingest 配置与近期日志（需本目录已 docker compose up）=========="
bash scripts/pilot-ingest-debug.sh || true

echo
echo "========== 3) 分层串流测试顺序（请人工执行，用于定位断在哪一层）=========="
echo "  A) Layer B（与 Redroid 无关）：两 Tab — 发布摄像头 / 仅观看。失败 → ICE/安全组/MEDIASOUP_ANNOUNCED_IP，见 docs/webrtc-sfu-pilot.md §3.2"
echo "  B) Layer C1 彩条：MEDIASOUP_INGEST_TEST=1 起 pilot 后  npm run c1:ingest -- --local ，页里仅观看。失败 → RTP/RTCP/mux/镜像未 build，见 docs/layer-c1-lessons-learned.md"
echo "  C) Redroid 真屏：掌厅前台 +  export MEDIASOUP_INGEST_CODEC=h264  +  npm run c1:ingest:adb -- --local"
echo "     黑屏先看：docker compose logs … rtpBytesReceived；为 0 则 adb/screenrecord 或端口未对齐；已涨但 framesDecoded=0 再查 H264 配置"
echo "  D) screenrecord 单测：  npm run c1:diagnose:adb"
echo
