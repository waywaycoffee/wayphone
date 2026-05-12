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
echo "  0) 停干净 / 单路 ingest（勿彩条+ADB 并行）: bash scripts/c1-ingest-safe.sh stop && bash scripts/c1-ingest-safe.sh status"
echo "  A) 浏览器这条腿（与 ADB 无关）：MEDIASOUP_INGEST_TEST=1 起 pilot →  npm run c1:ingest -- --local  （彩条）→ 页里仅观看"
echo "     另开 SSH:  npm run c1:diag:sfu   看 FFmpeg→SFU packetCount、SFU-to-browser outbound-rtp 是否 >0"
echo "     浏览器: chrome://webrtc-internals 看 ICE succeeded、inbound-rtp video bytes 是否涨"
echo "     彩条通、adb 不通 → 问题在 ADB→FFmpeg/screenrecord；彩条也不通 → 先修 SFU/RTCP/端口/ANNOUNCED_IP/安全组 UDP 40000–49999（见 docs/layer-c1-lessons-learned.md §12）"
echo "  B) ADB 只有几十包不涨： npm run c1:ingest:adb:short  （20s 段）或  npm run c1:ingest:adb:short:v  （带 screenrecord/ffmpeg 详细日志）"
echo "     持续跑： SCREENRECORD_TIME_LIMIT=20 npm run c1:ingest:adb:loop"
echo "  C) Producer 有包但 consumer 仍为 0：webrtc-internals + 安全组 + MEDIASOUP_ANNOUNCED_IP=EIP + 容器重启后重跑 run-c1"
echo "  D) Layer B（两 Tab 摄像头）：与 ingest 无关的 WebRTC 基线，见 docs/webrtc-sfu-pilot.md §3.2"
echo "  E) screenrecord 单测：  npm run c1:diagnose:adb"
echo
