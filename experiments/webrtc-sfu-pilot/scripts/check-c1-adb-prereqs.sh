#!/usr/bin/env bash
# 跑原生画面 ingest 前快速自检（在 experiments/webrtc-sfu-pilot 或仓库根执行均可）。
# 用法: bash scripts/check-c1-adb-prereqs.sh
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
_def=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh") || exit 1
eval "${_def}"

ok=0
fail() { echo "✗ $*" >&2; ok=1; }

command -v adb >/dev/null 2>&1 || fail "未找到 adb（请安装 Android platform-tools）"
command -v ffmpeg >/dev/null 2>&1 || fail "未找到 ffmpeg"

ADB_FLAGS=()
[[ -n "${ANDROID_SERIAL:-}" ]] && ADB_FLAGS+=(-s "${ANDROID_SERIAL}")

if adb "${ADB_FLAGS[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit(f?0:1)}'; then
  echo "✓ adb: 至少一台 device"
else
  fail "adb 无 device 状态（请 adb connect 127.0.0.1:5555 等）"
fi

if docker compose ps --status running 2>/dev/null | grep -q .; then
  echo "✓ docker compose 有运行中服务（请确认含 webrtc-sfu-pilot 且 MEDIASOUP_INGEST_TEST=1）"
else
  echo "○ docker compose 无运行中容器或未在本目录执行（可忽略若你本机仅检 adb）"
fi

if [[ "${ok}" != 0 ]]; then
  echo "" >&2
  echo "修复后: cd experiments/webrtc-sfu-pilot && npm run c1:ingest:adb -- --local" >&2
  exit 1
fi

echo ""
echo "下一步（与文档技术栈冻结一致，H264 ingest）:"
echo "  export MEDIASOUP_INGEST_CODEC=h264   # 与 Router 一致"
echo "  npm run c1:ingest:adb -- --local"
echo "  浏览器打开试点页 → 仅观看"
exit 0
